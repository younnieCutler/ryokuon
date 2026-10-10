#!/usr/bin/env bash
# Reproducible standalone MP3 helper. The source and this build recipe travel
# in every app bundle. No modifications to libmp3lame itself.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$ROOT/.build/lame-3.100.tar.gz"
source="$ROOT/.build/vendor/lame-3.100"
prefix="$ROOT/.build/vendor/lame-install"
mkdir -p "$ROOT/.build/vendor"
if [[ ! -f "$archive" ]]; then
  curl --proto '=https' --tlsv1.2 --retry 3 -fL https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz -o "$archive"
fi
expected=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected" ]] || { echo 'LAME source checksum mismatch' >&2; exit 1; }
if [[ ! -x "$prefix/bin/lame" ]]; then
  tar -xzf "$archive" -C "$ROOT/.build/vendor"
  (
    cd "$source"
    # Match Homebrew's upstream build fix for a removed legacy export.
    sed -i.bak '/^lame_init_old$/d' include/libmp3lame.sym
    CFLAGS='-O2 -std=c99' ./configure --prefix="$prefix" --disable-shared --enable-static --disable-decoder --disable-nasm --disable-dependency-tracking
    make -j2
    make install
  )
fi
