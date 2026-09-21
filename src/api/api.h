#ifndef API_H
#define API_H

#include "lauxlib.h"  // IWYU pragma: export
#include "lua.h"      // IWYU pragma: export
#include "lualib.h"   // IWYU pragma: export

#define API_TYPE_FONT "Font"

void api_load_libs(lua_State *L);

#endif
