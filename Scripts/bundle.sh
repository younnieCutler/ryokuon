#!/bin/bash
# Assembles Ryokuon.app from the SwiftPM build output and signs it with a
# fixed identity so TCC permission grants survive rebuilds (a re-signed
# binary with a different identity is a different app as far as TCC is
# concerned — see plan/2026-08-09-step0-results.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || { echo 'configuration must be debug or release' >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'build on an Apple silicon Mac' >&2; exit 1; }

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
cp "$ROOT/Resources/update-helper.sh" "$APP/Contents/Resources/update-helper.sh"
cp "$ROOT/bin/ryokuon" "$APP/Contents/MacOS/ryokuon-cli"
for region in en ko ja; do
  mkdir -p "$APP/Contents/Resources/$region.lproj"
  cp "$ROOT/Resources/$region.lproj/InfoPlist.strings" "$APP/Contents/Resources/$region.lproj/InfoPlist.strings"
done

# Compile the pinned encoder ourselves. A Homebrew binary can acquire new
# dynamic dependencies; it must not silently make clean-Mac installs fail.
bash "$ROOT/Scripts/build-lame.sh"
mkdir -p "$APP/Contents/Helpers"
cp "$ROOT/.build/vendor/lame-install/bin/lame" "$APP/Contents/Helpers/lame"
cp "$ROOT/.build/vendor/lame-3.100/COPYING" "$APP/Contents/Resources/LAME-LICENSE.txt"
cp "$ROOT/.build/lame-3.100.tar.gz" "$APP/Contents/Resources/lame-3.100-source.tar.gz"
cp "$ROOT/Scripts/build-lame.sh" "$APP/Contents/Resources/LAME-build.sh"
# Refuse non-system dynamic dependencies that would break on a clean Mac.
if otool -L "$APP/Contents/Helpers/lame" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
  echo 'lame has non-system dynamic dependencies' >&2
  exit 1
fi

# Inside-out: the helper is signed on its own first (no --deep on the app).
codesign -s "$IDENTITY" -f --timestamp --options runtime "$APP/Contents/Helpers/lame" >/dev/null
codesign -s "$IDENTITY" -f --timestamp --options runtime \
  --entitlements "$ROOT/Resources/Ryokuon.entitlements" "$APP" >/dev/null

echo "built $APP"
echo "launch with: open \"$APP\""
