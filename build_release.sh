#!/bin/bash
set -euo pipefail

cross="x86_64-w64-mingw32-"
sdl_dir="lib/win32/SDL2-2.0.10/x86_64-w64-mingw32"

./build.sh release windows portable
./build.sh release portable
rm -f lite.zip

# -----------------------------------------------------------------------------
# Windows DLLs
# -----------------------------------------------------------------------------
# Bundle all DLLs needed to run on windows
sysroot=$("${cross}gcc" -print-sysroot)
search_dirs=(
  "$sdl_dir/bin"
  "$sysroot/mingw/bin"                                    # Fedora
  "/usr/x86_64-w64-mingw32/lib"                           # Debian winpthreads
  "$(dirname "$("${cross}gcc" -print-libgcc-file-name)")" # Debian libgcc
)

find_dll() {
  local dir
  for dir in "${search_dirs[@]}"; do
    local match
    match=$(find "$dir" -maxdepth 1 -iname "$1" -print -quit 2>/dev/null || true)
    if [[ $match ]]; then
      echo "$match"
      return
    fi
  done
}

dll_imports() {
  "${cross}objdump" -p "$1" | sed -n 's/^\s*DLL Name: //p'
}

bundled=()
from_windows=()
pending=(lite.exe)
while (( ${#pending[@]} )); do
  binary=${pending[0]}
  pending=("${pending[@]:1}")
  while read -r dll; do
    # skip DLLs we've already handled, whichever way
    for seen in "${bundled[@]}" "${from_windows[@]}"; do
      [[ ${seen,,} == "${dll,,}" ]] && continue 2
    done
    path=$(find_dll "$dll")
    if [[ $path ]]; then
      cp "$path" "$dll"
      bundled+=("$dll")
      pending+=("$dll")
    else
      from_windows+=("$dll")
    fi
  done < <(dll_imports "$binary")
done
echo "bundling: ${bundled[*]}"
echo "assumed to ship with Windows: ${from_windows[*]}"

# -----------------------------------------------------------------------------
# Package
# -----------------------------------------------------------------------------

strip lite
"${cross}strip" lite.exe "${bundled[@]}"
zip -r lite.zip lite lite.exe "${bundled[@]}" data
rm -f "${bundled[@]}"
