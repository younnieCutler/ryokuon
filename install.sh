#!/bin/bash
# Ryokuon installer:
#   curl -fsSL https://raw.githubusercontent.com/younnieCutler/ryokuon/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/younnieCutler/ryokuon/main/install.sh | bash -s -- --uninstall
#
# Public installs require a signed, notarized app. Never bypass Gatekeeper.
set -euo pipefail

APP_NAME="Ryokuon"
BUNDLE_ID="dev.ryokuon.app"
URL="${RYOKUON_URL:-https://github.com/younnieCutler/ryokuon/releases/latest/download/Ryokuon.zip}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Do not send SIGTERM: it bypasses the app's recording/processing quit guard.
ensure_not_running() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        die "Finish recording or processing, then quit $APP_NAME before installing or uninstalling."
    fi
}

uninstall() {
    ensure_not_running
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
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$tmp/$APP_NAME.app/Contents/Info.plist")" = "$BUNDLE_ID" ] || die "unexpected app identity"
    spctl --assess --type execute "$tmp/$APP_NAME.app" || die "Gatekeeper did not approve this release. Use a signed, notarized public release."

    ensure_not_running
    say "Installing to $dest/$APP_NAME.app"
    local incoming="$dest/.$APP_NAME-incoming-$$.app"
    local backup="$dest/.$APP_NAME-previous-$$.app"
    [ ! -e "$incoming" ] && [ ! -e "$backup" ] || die "an installer staging path already exists"
    ditto "$tmp/$APP_NAME.app" "$incoming"
    codesign --verify --deep --strict "$incoming" || { rm -rf "$incoming"; die "staged app verification failed"; }
    if [ -d "$dest/$APP_NAME.app" ]; then mv "$dest/$APP_NAME.app" "$backup"; fi
    if ! mv "$incoming" "$dest/$APP_NAME.app"; then
        [ ! -d "$backup" ] || mv "$backup" "$dest/$APP_NAME.app"
        die "installation failed; the previous app was restored"
    fi
    # The previous installation stays recoverable rather than being deleted first.
    if [ -d "$backup" ]; then
        local previous_dir
        previous_dir="$(mktemp -d "$HOME/.Trash/Ryokuon-previous.XXXXXX")"
        mv "$backup" "$previous_dir/Ryokuon.app"
    fi

    say "Opening $APP_NAME — allow the microphone and audio permissions it asks for."
    open "$dest/$APP_NAME.app"
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "") install ;;
    *) die "unknown option: $1 (use --uninstall, or nothing to install)" ;;
esac
