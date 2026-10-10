# Contributing to Ryokuon

We want a dependable native meeting recorder that both everyday users and developers can trust. Start with a reproducible problem, then make the smallest coherent change that solves it.

## Setup and validation

Use an Apple silicon Mac, macOS 26+, Xcode 26 / Swift 6.2+ and `brew install lame` for MP3 tests. Run `bash Scripts/validate.sh`, then `bash Scripts/bundle.sh` with your development signing identity. CI uses ad-hoc signing only for development validation.

Never run destructive or crash-injection checks against actual recordings. Point `dev.ryokuon.storageRootPath` to a disposable directory and use synthetic or explicitly consented test audio. Record the old setting and restore it afterwards. Do not change a contributor's real `~/Documents/ryokuon`.

Fixes for recording, recovery, exports, metadata and path handling should include a regression test. Hardware-only fixes must document the device, steps, observed failure and actual rerun result. If you cannot build on macOS, state that explicitly instead of claiming compilation or UI validation.

Keep audio callbacks free of file I/O and allocation-heavy work. Keep UI work on the main actor, stream long audio, and preserve existing session metadata. Add user-visible strings in English, Japanese and Korean. Avoid introducing a cloud dependency into the default meeting workflow.

## Pull requests

Describe the user-visible problem, the resulting behavior and the validation performed. Attach screenshots from the actual app for UI changes, with fictional data. Identify untested hardware scenarios. Do not include private recordings or system credentials.

## Good first contributions

- Reproduce a hardware case from `docs/RELEASE.md` and contribute the result.
- Improve keyboard/VoiceOver access with before-and-after evidence.
- Add a regression fixture for an audio format or filename that failed to import.
- Improve translations while preserving technical meaning.

Use GitHub issues for bugs and feature proposals. Use the private reporting path in `SECURITY.md` for security vulnerabilities.
