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

codesign -s "$IDENTITY" -f --options runtime \
  --entitlements "$ROOT/Resources/Ryokuon.entitlements" "$APP" >/dev/null

echo "built $APP"
echo "launch with: open \"$APP\""
