#include "api.h"
#include "renderer.h"
#include "rencache.h"


static RenImage** push_image(lua_State *L, RenImage *image) {
  RenImage **self = lua_newuserdata(L, sizeof(*self));
  *self = image;
  luaL_setmetatable(L, API_TYPE_IMAGE);
  return self;
}


/* Returns nil and the reason on failure: a missing or unsupported file is an
** expected outcome for a document's images, not a programming error. */
static int f_load(lua_State *L) {
  const char *filename = luaL_checkstring(L, 1);
  const char *error = NULL;
  RenImage *image = ren_load_image(filename, &error);
  if (!image) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : "unknown error");
    return 2;
  }
  push_image(L, image);
  return 1;
}


static int f_gc(lua_State *L) {
  RenImage **self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  if (*self) { rencache_free_image(*self); }
  return 0;
}


static int f_get_size(lua_State *L) {
  RenImage **self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  int width, height;
  ren_get_image_size(*self, &width, &height);
  lua_pushnumber(L, width);
  lua_pushnumber(L, height);
  return 2;
}


static int f_resized(lua_State *L) {
  RenImage **self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  int width = luaL_checknumber(L, 2);
  int height = luaL_checknumber(L, 3);
  luaL_argcheck(L, width > 0 && width <= 16384, 2, "width out of range");
  luaL_argcheck(L, height > 0 && height <= 16384, 3, "height out of range");
  push_image(L, ren_resize_image(*self, width, height));
  return 1;
}


static const luaL_Reg lib[] = {
  { "__gc",     f_gc       },
  { "load",     f_load     },
  { "get_size", f_get_size },
  { "resized",  f_resized  },
  { NULL, NULL }
};

int luaopen_renderer_image(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_IMAGE);
  luaL_setfuncs(L, lib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}
