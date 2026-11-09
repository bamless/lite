#include "net.h"

#include <SDL2/SDL.h>
#include <SDL2/SDL_events.h>
#include <assert.h>
#include <curl/curl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static_assert(sizeof(((Net_Result *)0)->error) >= CURL_ERROR_SIZE, "error buffer too small");

#define container_of(ptr, T, member) ((T*)((unsigned char *)(ptr) - offsetof(T, member)))

uint32_t net_event_type = (uint32_t)-1;  // The net event type, UINT32_MAX until registered.
static int next_client_id = 0;

typedef enum {
  NET_CMD_ADD,
  NET_CMD_CANCEL,
} Net_Command_Type;

typedef struct Net_Command {
  struct Net_Command *next;
  Net_Command_Type type;
  struct Net_Request *request;
  int id;
} Net_Command;

struct Net_Request {
  struct Net_Request *next;   // link in the worker's active list
  int id;                     // request ID
  CURL *curl_easy;
  struct curl_slist *headers;
  bool has_body;              // wether this request has a body or not
  size_t max_size;            // 0 for unlimited
  const char *write_error;
  Net_Command add;            // command lives embedded in the request
  Net_Result result;          // curl writes body and error into it
};

struct Net_Client {
  int id;
  CURLM *multi;
  SDL_Thread *thread;
  SDL_mutex *lock;
  Net_Command *inbox_head, *inbox_tail;  // main -> worker queue
  Net_Result *outbox_head, *outbox_tail; // worker -> main queue
  bool notify_pending;
  bool quit;
  int next_request_id;
  long default_timeout_ms;
  char *user_agent;
};

bool net_init(void) {
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return false;
  net_event_type = SDL_RegisterEvents(1);
  if (net_event_type == (uint32_t)-1) return false;
  return true;
}

void net_quit(void) {
  curl_global_cleanup();
}

static bool buffer_append(Byte_Buffer *b, const void *data, size_t length) {
  if (b->length + length > b->capacity) {
    size_t capacity = b->capacity ? b->capacity : 4096;
    while (capacity < b->length + length) capacity *= 2;
    unsigned char *grown = realloc(b->data, capacity);
    if (!grown) return false;
    b->data = grown;
    b->capacity = capacity;
  }
  memcpy(b->data + b->length, data, length);
  b->length += length;
  return true;
}

void net_result_free(Net_Result *result) {
  free(result->body.data);
  free(result->content_type);
  free(container_of(result, Net_Request, result));
}

static size_t on_write(char *data, size_t size, size_t count, void *userdata) {
  Net_Request *r = userdata;
  size_t length = size * count;
  if (r->max_size && r->result.body.length + length > r->max_size) {
    r->write_error = "response exceeds max_size";
    return 0;
  }
  if (!buffer_append(&r->result.body, data, length)) {
    r->write_error = "out of memory";
    return 0;
  }
  return length;
}

Net_Request *net_request_new(Net_Client *c, const char *url, const char **error) {
  Net_Request *r = calloc(1, sizeof(*r));
  if (!r) {
    *error = "out of memory";
    return NULL;
  }

  r->curl_easy = curl_easy_init();
  if (!r->curl_easy) {
    *error = "curl_easy_init failed";
    net_request_free(r);
    return NULL;
  }

  CURL *e = r->curl_easy;
  curl_easy_setopt(e, CURLOPT_PRIVATE, r);
  curl_easy_setopt(e, CURLOPT_ERRORBUFFER, r->result.error);
  curl_easy_setopt(e, CURLOPT_WRITEFUNCTION, on_write);
  curl_easy_setopt(e, CURLOPT_WRITEDATA, r);
  curl_easy_setopt(e, CURLOPT_NOSIGNAL, 1L);  // signals are not thread-safe
  curl_easy_setopt(e, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(e, CURLOPT_MAXREDIRS, 10L);
  curl_easy_setopt(e, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(e, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(e, CURLOPT_ACCEPT_ENCODING, "");
  curl_easy_setopt(e, CURLOPT_USERAGENT, c->user_agent);
  curl_easy_setopt(e, CURLOPT_TIMEOUT_MS, c->default_timeout_ms);

  if (curl_easy_setopt(e, CURLOPT_URL, url) != CURLE_OK) {
    *error = "invalid url";
    net_request_free(r);
    return NULL;
  }

  return r;
}

bool net_request_set_body(Net_Request *r, const void *data, size_t length) {
  curl_easy_setopt(r->curl_easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)length);
  if (curl_easy_setopt(r->curl_easy, CURLOPT_COPYPOSTFIELDS, data) != CURLE_OK) return false;
  r->has_body = true;
  return true;
}

bool net_request_set_method(Net_Request *r, const char *method) {
  CURL *e = r->curl_easy;
  if (strcmp(method, "GET") == 0) {
    return curl_easy_setopt(e, CURLOPT_HTTPGET, 1L) == CURLE_OK;
  } else if (strcmp(method, "HEAD") == 0) {
    return curl_easy_setopt(e, CURLOPT_NOBODY, 1L) == CURLE_OK;
  } else if (strcmp(method, "POST") == 0) {
    // Without fields curl would read the body from stdin.
    return r->has_body || net_request_set_body(r, "", 0);
  }
  return curl_easy_setopt(e, CURLOPT_CUSTOMREQUEST, method) == CURLE_OK;
}

bool net_request_add_header(Net_Request *r, const char *name, const char *value) {
  // we try to add headers using a stack buffer. CURL copies the header
  // we pass to it, so we try to avoid unnecessary allocations.
  //
  // TODO: we probably should add an arena-like scratch allocator.
  char stack_line[256];
  size_t length = strlen(name) + strlen(value) + 3;
  char *line = length <= sizeof(stack_line) ? stack_line : malloc(length);
  if (!line) return false;
  snprintf(line, length, "%s: %s", name, value);
  struct curl_slist *headers = curl_slist_append(r->headers, line);
  if (line != stack_line) free(line);
  if (!headers) return false;
  r->headers = headers;
  curl_easy_setopt(r->curl_easy, CURLOPT_HTTPHEADER, r->headers);
  return true;
}

void net_request_set_timeout(Net_Request *r, long timeout_ms) {
  curl_easy_setopt(r->curl_easy, CURLOPT_TIMEOUT_MS, timeout_ms);
}

void net_request_set_max_size(Net_Request *r, size_t max_size) {
  r->max_size = max_size;
  curl_easy_setopt(r->curl_easy, CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)max_size);
}

// Releases the curl side of a request, leaving only the result behind.
static void release_transfer(Net_Request *r) {
  if (r->curl_easy) curl_easy_cleanup(r->curl_easy);
  curl_slist_free_all(r->headers);
  r->curl_easy = NULL;
  r->headers = NULL;
}

void net_request_free(Net_Request *r) {
  release_transfer(r);
  net_result_free(&r->result);
}

static void complete(Net_Request *r, CURLcode code) {
  Net_Result *res = &r->result;
  if (code == CURLE_OK) {
    char *content_type = NULL;
    curl_easy_getinfo(r->curl_easy, CURLINFO_RESPONSE_CODE, &res->status);
    curl_easy_getinfo(r->curl_easy, CURLINFO_CONTENT_TYPE, &content_type);
    if (content_type) res->content_type = strdup(content_type);
    return;
  }
  res->status = 0;
  free(res->body.data);
  res->body = (Byte_Buffer){0};
  if (r->write_error) {
    snprintf(res->error, sizeof(res->error), "%s", r->write_error);
  } else if (!res->error[0]) {
    snprintf(res->error, sizeof(res->error), "%s", curl_easy_strerror(code));
  }
}

static void fail(Net_Request *r, const char *error) {
  Net_Result *res = &r->result;
  res->status = 0;
  free(res->body.data);
  res->body = (Byte_Buffer){0};
  snprintf(res->error, sizeof(res->error), "%s", error);
}

static void deliver(Net_Client *c, Net_Request *r) {
  release_transfer(r);
  Net_Result *res = &r->result;

  SDL_LockMutex(c->lock);
  if (c->outbox_tail) c->outbox_tail->next = res;
  else c->outbox_head = res;
  c->outbox_tail = res;
  if (!c->notify_pending) {
    c->notify_pending = true;
    SDL_Event event = { .type = net_event_type };
    event.user.code = c->id;
    SDL_PushEvent(&event);
  }
  SDL_UnlockMutex(c->lock);
}

static Net_Request *unlink_request(Net_Request **list, Net_Request *target, int id) {
  for (Net_Request **p = list; *p; p = &(*p)->next) {
    Net_Request *r = *p;
    if (r == target || (!target && r->id == id)) {
      *p = r->next;
      r->next = NULL;
      return r;
    }
  }
  return NULL;
}

static int worker_main(void *data) {
  Net_Client *c = data;
  Net_Request *active = NULL;

  for (;;) {
    SDL_LockMutex(c->lock);
    Net_Command *commands = c->inbox_head;
    c->inbox_head = c->inbox_tail = NULL;
    bool quit = c->quit;
    SDL_UnlockMutex(c->lock);

    while (commands) {
      Net_Command *cmd = commands;
      commands = cmd->next;

      switch(cmd->type) {
      case NET_CMD_ADD: {
        Net_Request *r = cmd->request;
        CURLMcode code = curl_multi_add_handle(c->multi, r->curl_easy);
        if (code == CURLM_OK) {
          r->next = active;
          active = r;
        } else {
          fail(r, curl_multi_strerror(code));
          deliver(c, r);
        }
      } break;
      case NET_CMD_CANCEL: {
        Net_Request *r = unlink_request(&active, NULL, cmd->id);
        free(cmd);
        if (r) {
          curl_multi_remove_handle(c->multi, r->curl_easy);
          fail(r, "cancelled");
          deliver(c, r);
        }
      } break;
      }
    }

    if (quit) break;

    int running;
    curl_multi_perform(c->multi, &running);

    CURLMsg *msg;
    int remaining;
    while ((msg = curl_multi_info_read(c->multi, &remaining))) {
      if (msg->msg != CURLMSG_DONE) continue;
      CURL *easy = msg->easy_handle;
      CURLcode result = msg->data.result;  // `msg` dies with curl_multi_remove_handle
      Net_Request *r;
      curl_easy_getinfo(easy, CURLINFO_PRIVATE, (char **)&r);
      unlink_request(&active, r, 0);
      curl_multi_remove_handle(c->multi, easy);
      complete(r, result);
      deliver(c, r);
    }

    curl_multi_poll(c->multi, NULL, 0, 1000, NULL);
  }

  while (active) {
    Net_Request *r = active;
    active = r->next;
    curl_multi_remove_handle(c->multi, r->curl_easy);
    net_request_free(r);
  }
  return 0;
}

Net_Client *net_client_create(const Net_Client_Options *options, const char **error) {
  Net_Client *c = calloc(1, sizeof(*c));
  if (!c) {
    *error = "out of memory";
    return NULL;
  }

  c->id = ++next_client_id;
  c->default_timeout_ms = options->timeout_ms;

  c->multi = curl_multi_init();
  if (!c->multi) {
    *error = "curl_multi_init failed";
    goto fail;
  }

  curl_multi_setopt(c->multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, (long) options->max_connections);

  c->user_agent = strdup(options->user_agent);
  if (!c->user_agent) { *error = "out of memory"; goto fail; }

  c->lock = SDL_CreateMutex();
  if (!c->lock) {
    *error = SDL_GetError();
    goto fail;
  }

  c->thread = SDL_CreateThread(worker_main, "net", c);
  if (!c->thread) {
    *error = SDL_GetError();
    goto fail;
  }

  return c;

fail:
  if (c->lock) SDL_DestroyMutex(c->lock);
  free(c->user_agent);
  if (c->multi) curl_multi_cleanup(c->multi);
  free(c);
  return NULL;
}

void net_client_destroy(Net_Client *c) {
  SDL_LockMutex(c->lock);
  c->quit = true;
  SDL_UnlockMutex(c->lock);
  curl_multi_wakeup(c->multi);
  SDL_WaitThread(c->thread, NULL);

  while (c->inbox_head) {
    Net_Command *cmd = c->inbox_head;
    c->inbox_head = cmd->next;
    if (cmd->type == NET_CMD_ADD) {
      net_request_free(cmd->request);   // frees `cmd` too
    } else {
      free(cmd);
    }
  }
  while (c->outbox_head) {
    Net_Result *res = c->outbox_head;
    c->outbox_head = res->next;
    net_result_free(res);
  }

  SDL_DestroyMutex(c->lock);
  free(c->user_agent);
  curl_multi_cleanup(c->multi);
  free(c);
}

int net_client_id(const Net_Client *c) {
  return c->id;
}

static void enqueue(Net_Client *c, Net_Command *cmd) {
  cmd->next = NULL;
  SDL_LockMutex(c->lock);
  if (c->inbox_tail) c->inbox_tail->next = cmd;
  else c->inbox_head = cmd;
  c->inbox_tail = cmd;
  SDL_UnlockMutex(c->lock);

  curl_multi_wakeup(c->multi);
}

int net_client_submit(Net_Client *c, Net_Request *r) {
  int id = ++c->next_request_id;
  r->id = id;
  r->result.id = id;
  r->add = (Net_Command){ .type = NET_CMD_ADD, .request = r, .id = id };
  enqueue(c, &r->add);
  return id;
}

bool net_client_cancel(Net_Client *c, int id) {
  Net_Command *cmd = calloc(1, sizeof(*cmd));
  if (!cmd) return false;
  *cmd = (Net_Command){ .type = NET_CMD_CANCEL, .id = id };
  enqueue(c, cmd);
  return true;
}

Net_Result *net_client_poll(Net_Client *c) {
  SDL_LockMutex(c->lock);
  Net_Result *res = c->outbox_head;
  if (res) {
    c->outbox_head = res->next;
    if (!c->outbox_head) c->outbox_tail = NULL;
    res->next = NULL;
  } else {
    c->notify_pending = false;
  }
  SDL_UnlockMutex(c->lock);
  return res;
}
