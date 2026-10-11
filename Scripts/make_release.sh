#!/usr/bin/env bash
# Build a local development ZIP, or an explicitly notarized production release.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
[[ "$MODE" == '' || "$MODE" == --notarize || "$MODE" == --publish ]] || { echo 'use --notarize, --publish, or no arguments' >&2; exit 1; }
if [[ -n "$MODE" ]]; then
  [[ "${RYOKUON_SIGN_IDENTITY:-}" == 'Developer ID Application:'* ]] || { echo 'production releases require Developer ID Application signing' >&2; exit 1; }
  [[ -n "${RYOKUON_NOTARY_PROFILE:-}" ]] || { echo 'set RYOKUON_NOTARY_PROFILE to a notarytool keychain profile' >&2; exit 1; }
  bash "$ROOT/Scripts/validate.sh"
fi
bash "$ROOT/Scripts/bundle.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/.build/Ryokuon.zip"
ditto -c -k --keepParent "$ROOT/.build/Ryokuon.app" "$ZIP"
if [[ -n "$MODE" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$RYOKUON_NOTARY_PROFILE" --wait
  xcrun stapler staple "$ROOT/.build/Ryokuon.app"
  xcrun stapler validate "$ROOT/.build/Ryokuon.app"
  spctl --assess --type execute "$ROOT/.build/Ryokuon.app"
  rm "$ZIP"
  ditto -c -k --keepParent "$ROOT/.build/Ryokuon.app" "$ZIP"
  mkdir -p "$ROOT/.build/dmg"
  ditto "$ROOT/.build/Ryokuon.app" "$ROOT/.build/dmg/Ryokuon.app"
  [[ -L "$ROOT/.build/dmg/Applications" ]] || ln -s /Applications "$ROOT/.build/dmg/Applications"
  hdiutil create -volname Ryokuon -srcfolder "$ROOT/.build/dmg" -ov -format UDZO "$ROOT/.build/Ryokuon.dmg"
  codesign -s "$RYOKUON_SIGN_IDENTITY" --timestamp "$ROOT/.build/Ryokuon.dmg"
  xcrun notarytool submit "$ROOT/.build/Ryokuon.dmg" --keychain-profile "$RYOKUON_NOTARY_PROFILE" --wait
  xcrun stapler staple "$ROOT/.build/Ryokuon.dmg"
  xcrun stapler validate "$ROOT/.build/Ryokuon.dmg"
fi
(cd "$ROOT/.build" && shasum -a 256 Ryokuon.zip > SHA256SUMS)
if [[ "$MODE" == --publish ]]; then
  (cd "$ROOT/.build" && shasum -a 256 Ryokuon.dmg >> SHA256SUMS)
  gh release create "v$VERSION" "$ZIP" "$ROOT/.build/Ryokuon.dmg" "$ROOT/.build/SHA256SUMS" --draft --title "Ryokuon $VERSION" --generate-notes
fi
printf 'Built %s (v%s). Public release still requires hardware acceptance checks.\n' "$ZIP" "$VERSION"
