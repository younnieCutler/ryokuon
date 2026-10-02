#!/bin/bash
# Assembles Ryokuon.app from the SwiftPM build output and signs it with a
# fixed identity so TCC permission grants survive rebuilds (a re-signed
# binary with a different identity is a different app as far as TCC is
# concerned — see plan/2026-08-09-step0-results.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

if [ -z "${RYOKUON_SIGN_IDENTITY:-}" ]; then
  echo "error: RYOKUON_SIGN_IDENTITY not set — export it to your codesign identity" >&2
  echo '  e.g. export RYOKUON_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"' >&2
  echo "  find yours with: security find-identity -v -p codesigning" >&2
  exit 1
fi
IDENTITY="$RYOKUON_SIGN_IDENTITY"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Ryokuon"

APP="$ROOT/.build/Ryokuon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ryokuon"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# MP3 export shells out to lame (CoreAudio can't encode MP3). Ship it inside
# the app so a fresh Mac needs no Homebrew. Homebrew's lame links libmp3lame
# statically (only /usr/lib deps — checked with otool -L), so the one binary
# is enough. LGPL: the license travels with it.
LAME="$(command -v lame || true)"
if [ -z "$LAME" ]; then
  echo "error: lame not found — brew install lame (it gets bundled into the app)" >&2
  exit 1
fi
LAME_PREFIX="$(cd "$(dirname "$(readlink -f "$LAME")")/.." && pwd)"
mkdir -p "$APP/Contents/Helpers"
cp "$(readlink -f "$LAME")" "$APP/Contents/Helpers/lame"
cp "$LAME_PREFIX/COPYING" "$APP/Contents/Resources/LAME-LICENSE.txt"

# Inside-out: the helper is signed on its own first (no --deep on the app).
codesign -s "$IDENTITY" -f --options runtime "$APP/Contents/Helpers/lame" >/dev/null
codesign -s "$IDENTITY" -f --options runtime \
  --entitlements "$ROOT/Resources/Ryokuon.entitlements" "$APP" >/dev/null

echo "built $APP"
echo "launch with: open \"$APP\""
