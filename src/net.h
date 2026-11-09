#ifndef NET_H
#define NET_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

extern uint32_t net_event_type;  // `user.code` carries the client id

typedef struct Net_Client Net_Client;
typedef struct Net_Request Net_Request;

typedef struct {
  int max_connections;
  long timeout_ms;
  const char *user_agent;
} Net_Client_Options;

typedef struct {
  unsigned char *data;
  size_t length, capacity;
} Byte_Buffer;

typedef struct Net_Result {
  struct Net_Result *next;
  int id;
  long status;          // 0 on transport error
  Byte_Buffer body;
  char *content_type;   // NULL if the server sent none
  char error[256];      // empty on success
} Net_Result;

bool net_init(void);
void net_quit(void);

Net_Client *net_client_create(const Net_Client_Options *options, const char **error);
void net_client_destroy(Net_Client *client);
int net_client_id(const Net_Client *client);

Net_Request *net_request_new(Net_Client *client, const char *url, const char **error);
bool net_request_set_body(Net_Request *request, const void *data, size_t length);
bool net_request_set_method(Net_Request *request, const char *method);
bool net_request_add_header(Net_Request *request, const char *name, const char *value);
void net_request_set_timeout(Net_Request *request, long timeout_ms);
void net_request_set_max_size(Net_Request *request, size_t max_size);
void net_request_free(Net_Request *request);

int net_client_submit(Net_Client *client, Net_Request *request);  // takes ownership, never fails
bool net_client_cancel(Net_Client *client, int id);
Net_Result *net_client_poll(Net_Client *client);
void net_result_free(Net_Result *result);

#endif
