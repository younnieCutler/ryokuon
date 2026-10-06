#!/bin/bash
# Invoked by a running, signed Ryokuon after it has downloaded and verified a
# specific GitHub release. Wait for that process to exit before swapping apps.
set -euo pipefail

pid="$1"
target="$2"
staged="$3"
team="$4"
version="$5"
work="$6"

case "$target" in
  /Applications/Ryokuon.app|"$HOME/Applications/Ryokuon.app") ;;
  *) exit 2 ;;
esac
[[ "$(basename "$work")" == ryokuon-update-* ]] || exit 2
[[ "$staged" == "$work/unpacked/Ryokuon.app" ]] || exit 2
[[ -d "$target" && -d "$staged" ]] || exit 2

log="$HOME/Library/Logs/Ryokuon-update.log"
mkdir -p "$(dirname "$log")"
exec >>"$log" 2>&1

for ((attempt = 0; attempt < 100; attempt++)); do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
  echo "Ryokuon did not quit; update cancelled"
  exit 1
fi

parent="$(dirname "$target")"
incoming="$parent/.Ryokuon-update-$pid.app"
backup="$parent/.Ryokuon-backup-$pid.app"
[[ ! -e "$incoming" && ! -e "$backup" ]] || exit 2

verify_app() {
  local app="$1"
  /usr/bin/codesign --verify --deep --strict "$app"
  local actual_team
  actual_team="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2 }')"
  [[ "$actual_team" == "$team" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == dev.ryokuon.app ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
}

# Stage a complete copy on the destination volume before touching the old app.
/usr/bin/ditto "$staged" "$incoming"
verify_app "$incoming"

restore_old_app() {
  if [[ -d "$backup" ]]; then
    if [[ -d "$target" ]]; then mv "$target" "$incoming"; fi
    mv "$backup" "$target"
    open "$target" || true
  fi
}
trap restore_old_app EXIT

mv "$target" "$backup"
mv "$incoming" "$target"
verify_app "$target"
open "$target"
trap - EXIT

# Keep the previous app recoverable in Trash after the new one launches.
trash_dir="$(mktemp -d "$HOME/.Trash/Ryokuon-previous.XXXXXX")"
mv "$backup" "$trash_dir/Ryokuon.app"
rm -rf -- "$work"
echo "Updated Ryokuon to $version; previous app: $trash_dir/Ryokuon.app"
