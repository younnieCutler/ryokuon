#!/bin/bash
# Builds a release Ryokuon.app and zips it for install.sh to download.
#   bash Scripts/make_release.sh            # -> .build/Ryokuon.zip
#   bash Scripts/make_release.sh --publish  # + GitHub release v<version> with the zip
# install.sh fetches releases/latest/download/Ryokuon.zip, so the asset name
# must stay exactly Ryokuon.zip.
set -euo pipefail

if [ "${1:-}" = "--publish" ]; then
  [[ "${RYOKUON_SIGN_IDENTITY:-}" == "Developer ID Application:"* ]] || {
    echo "Public releases require a Developer ID Application signing identity." >&2
    exit 1
  }
  [ -n "${RYOKUON_NOTARY_PROFILE:-}" ] || {
    echo "Set RYOKUON_NOTARY_PROFILE to a notarytool keychain profile before publishing." >&2
    exit 1
  }
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/Scripts/bundle.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/.build/Ryokuon.zip"
# ditto, not zip: keeps the code signature and extended attributes intact.
ditto -c -k --keepParent "$ROOT/.build/Ryokuon.app" "$ZIP"
if [ -n "${RYOKUON_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$RYOKUON_NOTARY_PROFILE" --wait
  xcrun stapler staple "$ROOT/.build/Ryokuon.app"
  xcrun stapler validate "$ROOT/.build/Ryokuon.app"
  spctl --assess --type execute --verbose=2 "$ROOT/.build/Ryokuon.app"
  ditto -c -k --keepParent "$ROOT/.build/Ryokuon.app" "$ZIP"
fi
echo "built $ZIP (v$VERSION)"

if [ "${1:-}" = "--publish" ]; then
  gh release create "v$VERSION" "$ZIP" --title "Ryokuon $VERSION" --generate-notes
fi
