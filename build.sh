#!/bin/bash

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

cflags="-Wall -O3 -g -std=gnu11 -fno-strict-aliasing -Isrc -Ilib/LuaJIT/src"
lflags="-lSDL2 -lm"

if [[ $* == *release* ]]; then
  build="release"
  cflags="$cflags -DNDEBUG"
else
  build="debug"
fi

if [[ $* == *windows* ]]; then
  platform="windows"
  outfile="lite.exe"
  cross="x86_64-w64-mingw32-"
  march=""  # cross build is meant to be shipped: never tune for the build host
  luajit_flags=(CROSS="$cross" TARGET_SYS=Windows)
  cflags="$cflags -Ilib/win32/SDL2-2.0.10/x86_64-w64-mingw32/include"
  lflags="$lflags -Llib/win32/SDL2-2.0.10/x86_64-w64-mingw32/lib"
  lflags="-lmingw32 -lSDL2main $lflags -mwindows -o $outfile res.res"
  ${cross}windres res.rc -O coff -o res.res || exit 1
else
  platform="unix"
  outfile="lite"
  cross=""
  if [[ $* == *portable* ]]; then
    march=""
  else
    march="-march=native"
  fi
  luajit_flags=()
  lflags="$lflags -ldl -o $outfile"
fi

cflags="$cflags $march -flto"

compiler="${cross}gcc"
if command -v ccache >/dev/null; then
  compiler="ccache $compiler"
fi

luajit_dir="lib/LuaJIT"
luajit_stamp="$luajit_dir/.build-config"
luajit_ccopt="-O3 -fomit-frame-pointer $march"
luajit_xcflags="-DLUAJIT_ENABLE_LUA52COMPAT"
luajit_config="$platform|$luajit_ccopt|$luajit_xcflags"

echo "compiling LuaJIT..."

# make doesn't track flag changes, so force a clean rebuild whenever
# the platform or the flags differ from the previous build
if [[ ! -f $luajit_stamp || $(cat "$luajit_stamp") != "$luajit_config" ]]; then
  make -C "$luajit_dir" clean >/dev/null
fi

make -C "$luajit_dir/src" -j"$jobs" "${luajit_flags[@]}" \
  CCOPT="$luajit_ccopt"                                  \
  XCFLAGS="$luajit_xcflags"                              \
  BUILDMODE=static                                       \
  LJCORE_O=ljamalg.o libluajit.a || exit 1
echo "$luajit_config" > "$luajit_stamp"

lflags="$luajit_dir/src/libluajit.a $lflags"

echo "compiling ($platform, $build)..."

got_error=""
export compiler cflags
find src -name "*.c" -print0 |
  xargs -0 -n 1 -P "$jobs" bash -c '
    echo "$compiler -c $cflags $1"
    $compiler -c $cflags "$1" -o "${1//\//_}.o"
  ' _ || got_error=true

if [[ ! $got_error ]]; then
  echo "linking..."
  $compiler *.o $lflags -flto="$jobs" -O3 $march -g || got_error=true
fi

echo "cleaning up..."
rm -f *.o res.res

if [[ $got_error ]]; then
  echo "failed"
  exit 1
fi
echo "done"
