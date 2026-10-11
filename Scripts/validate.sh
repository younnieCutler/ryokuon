#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo 'Swift/macOS checks require macOS 26 + Xcode 26 (Swift 6.2+)' >&2; exit 1; }
swift --version
swift test --parallel
bash Scripts/test-cli.sh
bash -n install.sh Scripts/*.sh Resources/update-helper.sh bin/ryokuon
for plist in Resources/*.plist Resources/*.entitlements Resources/*.lproj/InfoPlist.strings; do plutil -lint "$plist"; done
