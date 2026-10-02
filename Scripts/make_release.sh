#!/bin/bash
# Builds a release Ryokuon.app and zips it for install.sh to download.
#   bash Scripts/make_release.sh            # -> .build/Ryokuon.zip
#   bash Scripts/make_release.sh --publish  # + GitHub release v<version> with the zip
# install.sh fetches releases/latest/download/Ryokuon.zip, so the asset name
# must stay exactly Ryokuon.zip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/Scripts/bundle.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/.build/Ryokuon.zip"
# ditto, not zip: keeps the code signature and extended attributes intact.
ditto -c -k --keepParent "$ROOT/.build/Ryokuon.app" "$ZIP"
echo "built $ZIP (v$VERSION)"

if [ "${1:-}" = "--publish" ]; then
  gh release create "v$VERSION" "$ZIP" --title "Ryokuon $VERSION" --generate-notes
fi
