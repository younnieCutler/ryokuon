#!/bin/bash
# Ryokuon installer:
#   curl -fsSL https://raw.githubusercontent.com/younnieCutler/ryokuon/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/younnieCutler/ryokuon/main/install.sh | bash -s -- --uninstall
#
# Why a script instead of a DMG: Gatekeeper only vets files carrying the
# com.apple.quarantine flag, which browsers add and curl doesn't — so a
# curl-installed app opens without notarization prompts.
set -euo pipefail

APP_NAME="Ryokuon"
BUNDLE_ID="dev.ryokuon.app"
URL="${RYOKUON_URL:-https://github.com/younnieCutler/ryokuon/releases/latest/download/Ryokuon.zip}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Quitting mid-recording would cut the recording short — refuse instead.
ensure_not_recording() {
    pgrep -x "$APP_NAME" >/dev/null || return 0
    local root
    root="$(defaults read "$BUNDLE_ID" dev.ryokuon.storageRootPath 2>/dev/null || echo "$HOME/Documents/ryokuon")"
    if grep -ls '"state" : "recording"' "$root"/*/session.json >/dev/null 2>&1; then
        die "$APP_NAME is recording right now — stop the recording, then run this again."
    fi
    say "Quitting the running $APP_NAME"
    pkill -TERM -x "$APP_NAME" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || return 0; sleep 0.5; done
    die "$APP_NAME didn't quit — quit it manually and run this again."
}

uninstall() {
    ensure_not_recording
    for dir in /Applications "$HOME/Applications"; do
        if [ -d "$dir/$APP_NAME.app" ]; then
            say "Removing $dir/$APP_NAME.app"
            rm -rf "${dir:?}/$APP_NAME.app"
        fi
    done
    say "Removing settings and privacy permissions"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
    say "Done. Recordings were kept in ~/Documents/ryokuon (delete that folder yourself if you want them gone)."
}

install() {
    [ "$(uname -m)" = "arm64" ] || die "$APP_NAME needs an Apple silicon Mac."
    [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || die "$APP_NAME needs macOS 26 or later."

    local dest=/Applications
    [ -w "$dest" ] || dest="$HOME/Applications"
    mkdir -p "$dest"

    # Global, not `local`: the EXIT trap runs after this function returns.
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    say "Downloading $APP_NAME"
    curl -fL --progress-bar "$URL" -o "$tmp/$APP_NAME.zip" || die "download failed: $URL"
    ditto -x -k "$tmp/$APP_NAME.zip" "$tmp"
    [ -d "$tmp/$APP_NAME.app" ] || die "the download didn't contain $APP_NAME.app"
    codesign --verify --deep --strict "$tmp/$APP_NAME.app" 2>/dev/null || die "signature check failed — download corrupted?"

    ensure_not_recording
    say "Installing to $dest/$APP_NAME.app"
    rm -rf "${dest:?}/$APP_NAME.app"
    ditto "$tmp/$APP_NAME.app" "$dest/$APP_NAME.app"
    xattr -dr com.apple.quarantine "$dest/$APP_NAME.app" 2>/dev/null || true

    say "Opening $APP_NAME — allow the microphone and audio permissions it asks for."
    open "$dest/$APP_NAME.app"
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "") install ;;
    *) die "unknown option: $1 (use --uninstall, or nothing to install)" ;;
esac
