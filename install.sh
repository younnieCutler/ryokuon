#!/usr/bin/env bash
# Optional installer for notarized releases. Gatekeeper remains enabled.
# The maintainer's verified 10-character Apple Team ID must be supplied.
set -euo pipefail
APP_NAME=Ryokuon
BUNDLE_ID=dev.ryokuon.app
URL="${RYOKUON_URL:-https://github.com/younnieCutler/ryokuon/releases/latest/download/Ryokuon.zip}"
say() { printf '==> %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
ensure_not_running() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        die 'Quit Ryokuon normally before installing or uninstalling. Running recordings and conversions are left untouched.'
    fi
}
verify_app() {
    local app="$1" actual_team
    [[ -d "$app" && ! -L "$app" ]] || die 'invalid application bundle'
    codesign --verify --deep --strict "$app" || die 'invalid code signature'
    actual_team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2 }')"
    [[ "$actual_team" == "$RYOKUON_TEAM_ID" ]] || die 'publisher Team ID mismatch'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$BUNDLE_ID" ]] || die 'bundle ID mismatch'
    xcrun stapler validate "$app" || die 'missing or invalid notarization ticket'
    spctl --assess --type execute "$app" || die 'Gatekeeper rejected this app'
}
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 && -n "${backup:-}" && -d "$backup" ]]; then
        [[ ! -e "$destination" ]] || rm -rf -- "$destination"
        mv "$backup" "$destination"
        say 'Installation failed; the previous app was restored.'
    fi
    [[ -z "${staging:-}" ]] || rm -rf -- "$staging"
    [[ -z "${download:-}" ]] || rm -rf -- "$download"
    exit "$status"
}
uninstall() {
    ensure_not_running
    for parent in /Applications "$HOME/Applications"; do
        [[ ! -L "$parent/$APP_NAME.app" ]] || die 'refusing a symlinked app'
        if [[ -d "$parent/$APP_NAME.app" ]]; then rm -rf -- "$parent/$APP_NAME.app"; fi
    done
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
    say 'App and settings removed. All recording folders were kept.'
}
install() {
    [[ "$(uname -m)" == arm64 ]] || die 'Ryokuon needs Apple silicon.'
    [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]] || die 'Ryokuon needs macOS 26 or later.'
    [[ "${RYOKUON_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || die 'Set RYOKUON_TEAM_ID to the verified publisher Team ID from the release notes.'
    [[ "$URL" == https://github.com/younnieCutler/ryokuon/releases/*/Ryokuon.zip ]] || die 'unsupported release URL'
    ensure_not_running
    local parent=/Applications
    [[ -w "$parent" ]] || parent="$HOME/Applications"
    mkdir -p "$parent"
    destination="$parent/$APP_NAME.app"
    [[ ! -L "$destination" ]] || die 'refusing a symlinked app'
    download="$(mktemp -d)"
    staging="$(mktemp -d "$parent/.Ryokuon-install.XXXXXX")"
    trap cleanup EXIT
    say 'Downloading the release'
    curl --proto '=https' --tlsv1.2 -fL --progress-bar "$URL" -o "$download/Ryokuon.zip"
    ditto -x -k "$download/Ryokuon.zip" "$download/unpacked"
    verify_app "$download/unpacked/Ryokuon.app"
    ditto "$download/unpacked/Ryokuon.app" "$staging/Ryokuon.app"
    verify_app "$staging/Ryokuon.app"
    ensure_not_running
    if [[ -d "$destination" ]]; then
        backup="$staging/previous.app"
        mv "$destination" "$backup"
    fi
    mv "$staging/Ryokuon.app" "$destination"
    verify_app "$destination"
    open "$destination"
    say 'Installed Ryokuon. Your recordings and settings were preserved.'
}
case "${1:-}" in
    --uninstall) uninstall ;;
    '') install ;;
    *) die 'Use --uninstall or no arguments.' ;;
esac
