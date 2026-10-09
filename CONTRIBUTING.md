# Contributing

Ryokuon targets Apple silicon, macOS 26 and Swift 6.2+. No third-party Swift packages are required. Install `lame` with Homebrew to exercise MP3 integration tests.

## Verification

```bash
swift build -Xswiftc -warnings-as-errors
swift test
swift test --sanitize=thread
bash -n install.sh Scripts/bundle.sh Scripts/make_release.sh Resources/update-helper.sh
```

Audio-device-dependent tests declare their requirement and skip when the runner has no output device. Report skipped tests explicitly; they do not count as hardware validation. Speech model, permissions and live recording checks are manual release gates.

Regression coverage includes nested session identity, failed Trash operations, recording target selection, pause/seek/resume, streaming channel/gain boundaries, resampling, export collisions and the RIFF size boundary.

## Isolated GUI testing

Quit the app. Save the existing value of `defaults read dev.ryokuon.app dev.ryokuon.storageRootPath`, including whether the key is absent. Then:

```bash
E2E_ROOT=$(mktemp -d)
defaults write dev.ryokuon.app dev.ryokuon.storageRootPath -string "$E2E_ROOT"
```

Launch a signed test build and confirm Settings points at that exact temporary folder. Do not use `~/Documents/ryokuon`. After quitting, restore the prior value, or delete only this key if it was absent:

```bash
defaults delete dev.ryokuon.app dev.ryokuon.storageRootPath
```

Never delete the whole defaults domain. Do not pass a defaults override as a launch argument: command-line arguments enter the developer CLI. Use synthetic audio; do not upload private recordings or transcripts.

## Changes

Use focused commits. Include a reproduction or concrete workflow, the changed behavior, tests and any unverified macOS/hardware paths. A Linux static review must explicitly say Swift was not compiled. Provide real light/dark screenshots and keyboard/VoiceOver evidence for interface changes; do not substitute mockups for runtime proof.

Add every new UI string to Japanese, Korean and English. Preserve on-disk session compatibility. Do not add silent audio uploads, automatic fallback to a different call target, destructive installers or unsigned distribution shortcuts.
