@echo off
setlocal

rem download this:
rem https://nuwen.net/mingw.html

rem change to mingw32-make if your MinGW distro names it that way
set MAKE=make

set LUAJIT_DIR=lib/LuaJIT
set LUAJIT_STAMP=lib\LuaJIT\.build-config
set LUAJIT_XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT
set LUAJIT_CONFIG=windows %LUAJIT_XCFLAGS%

echo compiling LuaJIT...
rem LuaJIT's make doesn't track config changes, so clean when they differ
set LAST_CONFIG=
if exist "%LUAJIT_STAMP%" set /p LAST_CONFIG=<"%LUAJIT_STAMP%"
if not "%LAST_CONFIG%"=="%LUAJIT_CONFIG%" %MAKE% -C %LUAJIT_DIR%/src clean >nul
%MAKE% -C %LUAJIT_DIR%/src XCFLAGS="%LUAJIT_XCFLAGS%" BUILDMODE=static LJCORE_O=ljamalg.o libluajit.a
if errorlevel 1 goto fail
>"%LUAJIT_STAMP%" echo %LUAJIT_CONFIG%

echo compiling (windows)...
windres res.rc -O coff -o res.res
if errorlevel 1 goto fail

gcc src/*.c src/api/*.c src/lib/stb/*.c^
    -O3 -s -std=gnu11 -fno-strict-aliasing -Isrc -DNDEBUG^
    -I%LUAJIT_DIR%/src^
    -Iwinlib/SDL2-2.0.10/x86_64-w64-mingw32/include^
    %LUAJIT_DIR%/src/libluajit.a^
    -lmingw32 -lm -lSDL2main -lSDL2 -Lwinlib/SDL2-2.0.10/x86_64-w64-mingw32/lib^
    -mwindows res.res^
    -o lite.exe
if errorlevel 1 goto fail

del res.res
echo done
exit /b 0

:fail
del res.res 2>nul
echo failed
exit /b 1
