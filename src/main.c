#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL2/SDL.h>
#include "api/api.h"
#include "renderer.h"

#ifdef _WIN32
  #include <windows.h>
#elif __linux__
  #include <unistd.h>
#elif __APPLE__
  #include <mach-o/dyld.h>
#endif


SDL_Window *window;


static bool scale_from_env(const char *name, double *scale) {
  const char *str = getenv(name);
  if (!str) { return false; }
  char *end;
  double n = strtod(str, &end);
  if (end == str || n <= 0) { return false; }
  *scale = n;
  return true;
}


/* The factor lite multiplies font sizes and paddings by. No platform offers
** one portable answer, so ask the sources each one actually has, most
** authoritative first. `LITE_SCALE` overrides all of this. */
static double get_scale(void) {
  float dpi = 0;
  bool have_dpi = SDL_GetDisplayDPI(0, NULL, &dpi, NULL) == 0 && dpi > 0;

#if _WIN32
  return have_dpi ? dpi / 96.0 : 1.0;

#elif __APPLE__
  /* macOS scales the window itself, so the surface is in points rather than
  ** pixels; scaling here as well would apply it twice */
  return 1.0;

#else
  const char *driver = SDL_GetCurrentVideoDriver();

  /* on Wayland this is the compositor's content scale: the setting the user
  ** picked, which is exactly what we want */
  if (driver && strcmp(driver, "wayland") == 0 && have_dpi) {
    return dpi / 96.0;
  }

  /* what the session tells toolkit apps: GDK_SCALE is an integer factor and
  ** GDK_DPI_SCALE an extra text multiplier on top of it */
  double scale, dpi_scale;
  if (scale_from_env("GDK_SCALE", &scale)) {
    if (scale_from_env("GDK_DPI_SCALE", &dpi_scale)) { scale *= dpi_scale; }
    return scale;
  }
  if (scale_from_env("QT_SCALE_FACTOR", &scale)) { return scale; }

  /* Last resort on X11, where SDL reports the panel's physical DPI rather
  ** than a user setting. A dense laptop screen with no desktop scaling would
  ** report about 1.6 and make everything too large, so only take clearly
  ** HiDPI values, snapped to quarter steps. */
  if (have_dpi && dpi / 96.0 >= 1.5) {
    return (int) (dpi / 96.0 * 4 + 0.5) / 4.0;
  }

  return 1.0;
#endif
}


static void get_exe_filename(char *buf, int sz) {
#if _WIN32
  int len = GetModuleFileName(NULL, buf, sz - 1);
  buf[len] = '\0';
#elif __linux__
  char path[512];
  sprintf(path, "/proc/%d/exe", getpid());
  int len = readlink(path, buf, sz - 1);
  buf[len] = '\0';
#elif __APPLE__
  unsigned size = sz;
  _NSGetExecutablePath(buf, &size);
#else
  strcpy(buf, "./lite");
#endif
}


static void init_window_icon(void) {
#ifndef _WIN32
  #include "../icon.inl"
  (void) icon_rgba_len; /* unused */
  SDL_Surface *surf = SDL_CreateRGBSurfaceFrom(
    icon_rgba, 64, 64,
    32, 64 * 4,
    0x000000ff,
    0x0000ff00,
    0x00ff0000,
    0xff000000);
  SDL_SetWindowIcon(window, surf);
  SDL_FreeSurface(surf);
#endif
}


int main(int argc, char **argv) {
#ifdef _WIN32
  HINSTANCE lib = LoadLibrary("user32.dll");
  int (*SetProcessDPIAware)() = (void*) GetProcAddress(lib, "SetProcessDPIAware");
  SetProcessDPIAware();
#endif

  SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
  SDL_EnableScreenSaver();
  SDL_EventState(SDL_DROPFILE, SDL_ENABLE);
  atexit(SDL_Quit);

#ifdef SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR /* Available since 2.0.8 */
  SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
#endif
#if SDL_VERSION_ATLEAST(2, 0, 5)
  SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
#endif

  SDL_DisplayMode dm;
  SDL_GetCurrentDisplayMode(0, &dm);

  window = SDL_CreateWindow(
    "", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, dm.w * 0.8, dm.h * 0.8,
    SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_HIDDEN);
  init_window_icon();
  ren_init(window);


  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  api_load_libs(L);


  lua_newtable(L);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setglobal(L, "ARGS");

  lua_pushstring(L, "1.11");
  lua_setglobal(L, "VERSION");

  lua_pushstring(L, SDL_GetPlatform());
  lua_setglobal(L, "PLATFORM");

  lua_pushnumber(L, get_scale());
  lua_setglobal(L, "SCALE");

  char exename[2048];
  get_exe_filename(exename, sizeof(exename));
  lua_pushstring(L, exename);
  lua_setglobal(L, "EXEFILE");


  (void) luaL_dostring(L,
    "local core\n"
    "xpcall(function()\n"
    "  SCALE = tonumber(os.getenv(\"LITE_SCALE\")) or SCALE\n"
    "  PATHSEP = package.config:sub(1, 1)\n"
    "  EXEDIR = EXEFILE:match(\"^(.+)[/\\\\].*$\")\n"
    "  package.path = EXEDIR .. '/data/?.lua;' .. package.path\n"
    "  package.path = EXEDIR .. '/data/?/init.lua;' .. package.path\n"
    "  core = require('core')\n"
    "  core.init()\n"
    "  core.run()\n"
    "end, function(err)\n"
    "  print('Error: ' .. tostring(err))\n"
    "  print(debug.traceback(nil, 2))\n"
    "  if core and core.on_error then\n"
    "    pcall(core.on_error, err)\n"
    "  end\n"
    "  os.exit(1)\n"
    "end)");


  lua_close(L);
  SDL_DestroyWindow(window);

  return EXIT_SUCCESS;
}
