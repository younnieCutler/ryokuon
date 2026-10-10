#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export RYOKUON_ROOT="$fixture/library"
mkdir -p "$RYOKUON_ROOT/project/session"
printf '{}\n' > "$RYOKUON_ROOT/project/session/session.json"
printf '0|M|release [plan]\n1000|R|approved\n2000|M|follow up\n' > "$RYOKUON_ROOT/project/session/transcript.txt"
[[ "$(bash "$ROOT/bin/ryokuon" list)" == project/session ]]
[[ "$(bash "$ROOT/bin/ryokuon" range project/session 1000 1000)" == '1000|R|approved' ]]
[[ "$(bash "$ROOT/bin/ryokuon" search project/session '[plan]')" == *'release [plan]'* ]]
if bash "$ROOT/bin/ryokuon" show ../outside 2>/dev/null; then exit 1; fi
mkdir -p "$fixture/outside"
printf 'private\n' > "$fixture/outside/transcript.txt"
ln -s "$fixture/outside" "$RYOKUON_ROOT/link"
if bash "$ROOT/bin/ryokuon" show link 2>/dev/null; then exit 1; fi
if bash "$ROOT/bin/ryokuon" range project/session invalid 1000 2>/dev/null; then exit 1; fi
printf 'CLI checks passed\n'
