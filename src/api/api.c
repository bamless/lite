#include "api.h"


int luaopen_system(lua_State *L);
int luaopen_renderer(lua_State *L);


#if LUA_VERSION_NUM < 502
/* Lua 5.2's luaL_requiref, for Lua 5.1 / LuaJIT.
   Leaves a copy of the module on the stack, like the original. */
static void luaL_requiref(lua_State *L, const char *modname,
                          lua_CFunction openf, int glb) {
  lua_pushcfunction(L, openf);
  lua_pushstring(L, modname);
  lua_call(L, 1, 1);

  /* package.loaded[modname] = module */
  lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
  lua_pushvalue(L, -2);
  lua_setfield(L, -2, modname);
  lua_pop(L, 1);

  if (glb) {
    lua_pushvalue(L, -1);
    lua_setglobal(L, modname);
  }
}
#endif


static const luaL_Reg libs[] = {
  { "system",    luaopen_system     },
  { "renderer",  luaopen_renderer   },
  { NULL, NULL }
};

void api_load_libs(lua_State *L) {
  for (int i = 0; libs[i].name; i++) {
    luaL_requiref(L, libs[i].name, libs[i].func, 1);
  }
}
