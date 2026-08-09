#!/bin/bash
# Assembles Ryokuon.app from the SwiftPM build output and signs it with a
# fixed identity so TCC permission grants survive rebuilds (a re-signed
# binary with a different identity is a different app as far as TCC is
# concerned — see plan/2026-08-09-step0-results.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${RYOKUON_SIGN_IDENTITY:-Apple Development: ehrktm090@gmail.com (7TFR357KWQ)}"
CONFIG="${1:-debug}"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Ryokuon"

APP="$ROOT/.build/Ryokuon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ryokuon"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign -s "$IDENTITY" -f --options runtime \
  --entitlements "$ROOT/Resources/Ryokuon.entitlements" "$APP" >/dev/null

echo "built $APP"
echo "launch with: open \"$APP\""
