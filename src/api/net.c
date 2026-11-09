#include "api.h"
#include "net.h"

#include <stdbool.h>
#include <stdint.h>

static int opt_field(lua_State *L, int idx, const char *key) {
  if (lua_isnoneornil(L, idx)) return 0;
  luaL_checktype(L, idx, LUA_TTABLE);
  lua_getfield(L, idx, key);
  if (lua_isnil(L, -1)) { lua_pop(L, 1); return 0; }
  return 1;
}

static int opt_int(lua_State *L, int idx, const char *key, int def) {
  if (!opt_field(L, idx, key)) return def;
  if (!lua_isnumber(L, -1)) luaL_error(L, "option '%s' must be a number", key);
  int value = (int) lua_tointeger(L, -1);
  lua_pop(L, 1);
  return value;
}

static double opt_number(lua_State *L, int idx, const char *key, double def) {
  if (!opt_field(L, idx, key)) return def;
  if (!lua_isnumber(L, -1)) luaL_error(L, "option '%s' must be a number", key);
  double value = lua_tonumber(L, -1);
  lua_pop(L, 1);
  return value;
}

static const char *opt_string(lua_State *L, int idx, const char *key, const char *def) {
  if (!opt_field(L, idx, key)) return def;
  if (!lua_isstring(L, -1)) luaL_error(L, "option '%s' must be a string", key);
  const char *value = lua_tostring(L, -1);
  lua_pop(L, 1);
  return value;
}

static int f_client(lua_State *L) {
  if (net_event_type == (uint32_t) -1) return luaL_error(L, "SDL_RegisterEvents failed");
  Net_Client_Options options = {
    .max_connections = opt_int(L, 1, "max_connections", 4),
    .timeout_ms      = (long) (opt_number(L, 1, "timeout", 30) * 1000),
    .user_agent      = opt_string(L, 1, "user_agent", "lite"),
  };

  Net_Client **self = lua_newuserdata(L, sizeof(*self));
  *self = NULL;
  luaL_setmetatable(L, API_TYPE_NET_CLIENT);

  const char *error = NULL;
  *self = net_client_create(&options, &error);
  if (!*self) return luaL_error(L, "net.client: %s", error ? error : "unknown error");
  return 1;
}

static Net_Client *check_client(lua_State *L, int idx) {
  Net_Client **self = luaL_checkudata(L, idx, API_TYPE_NET_CLIENT);
  if (!*self) luaL_error(L, "client is closed");
  return *self;
}

static int f_client_close(lua_State *L) {
  Net_Client **self = luaL_checkudata(L, 1, API_TYPE_NET_CLIENT);
  if (*self) {
    net_client_destroy(*self);
    *self = NULL;
  }
  return 0;
}

static int f_client_get_id(lua_State *L) {
  lua_pushinteger(L, net_client_id(check_client(L, 1)));
  return 1;
}

/* client:request{ url=, method=, headers={ [name]=value }, body=, timeout=, max_size= } -> id */
static int f_client_request(lua_State *L) {
  Net_Client *client = check_client(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);

  const char *url = opt_string(L, 2, "url", NULL);
  if (!url) return luaL_error(L, "option 'url' is required");
  const char *method = opt_string(L, 2, "method", NULL);
  double timeout = opt_number(L, 2, "timeout", -1);
  double max_size = opt_number(L, 2, "max_size", 0);
  if (max_size < 0) return luaL_error(L, "option 'max_size' must be positive");

  size_t body_length = 0;
  const char *body = NULL;
  if (opt_field(L, 2, "body")) {
    if (lua_type(L, -1) != LUA_TSTRING) return luaL_error(L, "option 'body' must be a string");
    body = lua_tolstring(L, -1, &body_length);
    lua_pop(L, 1);
  }

  int headers = 0;
  if (opt_field(L, 2, "headers")) {
    if (!lua_istable(L, -1)) return luaL_error(L, "option 'headers' must be a table");
    headers = lua_gettop(L);
    for (lua_pushnil(L); lua_next(L, headers); lua_pop(L, 1)) {
      if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
        return luaL_error(L, "header names and values must be strings");
      }
    }
  }

  const char *error = NULL;
  Net_Request *request = net_request_new(client, url, &error);
  if (!request) return luaL_error(L, "client:request: %s", error);

  bool ok = true;
  if (body) ok = ok && net_request_set_body(request, body, body_length);
  if (method) ok = ok && net_request_set_method(request, method);
  if (headers) {
    for (lua_pushnil(L); lua_next(L, headers); lua_pop(L, 1)) {
      ok = ok && net_request_add_header(request, lua_tostring(L, -2), lua_tostring(L, -1));
    }
  }
  if (timeout >= 0) net_request_set_timeout(request, (long) (timeout * 1000));
  if (max_size > 0) net_request_set_max_size(request, (size_t) max_size);
  if (!ok) {
    net_request_free(request);
    return luaL_error(L, "client:request: out of memory");
  }

  lua_pushinteger(L, net_client_submit(client, request));
  return 1;
}

static int f_client_cancel(lua_State *L) {
  Net_Client *client = check_client(L, 1);
  int id = luaL_checkinteger(L, 2);
  if (!net_client_cancel(client, id)) return luaL_error(L, "client:cancel: out of memory");
  return 0;
}

/* client:poll() -> { id=, status=, body=, content_type=, error= } or nil */
static int f_client_poll(lua_State *L) {
  Net_Client *client = check_client(L, 1);
  Net_Result *result = net_client_poll(client);
  if (!result) return 0;

  // Popped already: a memory error below would leak it, which we accept.
  lua_createtable(L, 0, 5);
  lua_pushinteger(L, result->id);
  lua_setfield(L, -2, "id");
  lua_pushinteger(L, result->status);
  lua_setfield(L, -2, "status");
  lua_pushlstring(L, (const char *) result->body.data, result->body.length);
  lua_setfield(L, -2, "body");
  if (result->content_type) {
    lua_pushstring(L, result->content_type);
    lua_setfield(L, -2, "content_type");
  }
  if (result->error[0]) {
    lua_pushstring(L, result->error);
    lua_setfield(L, -2, "error");
  }
  net_result_free(result);
  return 1;
}

static const luaL_Reg client_methods[] = {
  { "__gc",    f_client_close   },
  { "close",   f_client_close   },
  { "get_id",  f_client_get_id  },
  { "request", f_client_request },
  { "cancel",  f_client_cancel  },
  { "poll",    f_client_poll    },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "client", f_client },
  { NULL, NULL }
};

int luaopen_net(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_NET_CLIENT);
  luaL_setfuncs(L, client_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, lib);
  return 1;
}
