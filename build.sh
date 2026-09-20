#!/bin/bash

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
  luajit_flags=(CROSS="$cross" TARGET_SYS=Windows)
  cflags="$cflags -Ilib/win32/SDL2-2.0.10/x86_64-w64-mingw32/include"
  lflags="$lflags -Llib/win32/SDL2-2.0.10/x86_64-w64-mingw32/lib"
  lflags="-lmingw32 -lSDL2main $lflags -mwindows -o $outfile res.res"
  ${cross}windres res.rc -O coff -o res.res || exit 1
else
  platform="unix"
  outfile="lite"
  cross=""
  luajit_flags=()
  lflags="$lflags -ldl -o $outfile"
fi

compiler="${cross}gcc"
if command -v ccache >/dev/null; then
  compiler="ccache $compiler"
fi

luajit_dir="lib/LuaJIT"
luajit_stamp="$luajit_dir/.build-platform"

echo "compiling LuaJIT..."
if [[ ! -f $luajit_stamp || $(cat "$luajit_stamp") != "$platform" ]]; then
  make -C "$luajit_dir" clean >/dev/null
fi
make -C "$luajit_dir/src" "${luajit_flags[@]}" \
  XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT"        \
  BUILDMODE=static                             \
  LJCORE_O=ljamalg.o libluajit.a || exit 1
echo "$platform" > "$luajit_stamp"

lflags="$luajit_dir/src/libluajit.a $lflags"

echo "compiling ($platform, $build)..."

set -x
got_error=""
for f in $(find src -name "*.c"); do
  if ! $compiler -c $cflags "$f" -o "${f//\//_}.o"; then
    got_error=true
  fi
done
set +x

if [[ ! $got_error ]]; then
  echo "linking..."
  $compiler *.o $lflags || got_error=true
fi

echo "cleaning up..."
rm -f *.o res.res

if [[ $got_error ]]; then
  echo "failed"
  exit 1
fi
echo "done"
