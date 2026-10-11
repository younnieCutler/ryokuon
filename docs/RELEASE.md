# Production release checklist

Do not call a build production-ready from unit tests alone. Complete this checklist and attach the measured evidence to the release PR.

## Automated gate

- Green macOS 26 CI for the exact release commit: Swift tests, release build, bundle verification and CLI containment checks.
- Run `bash Scripts/validate.sh` locally with the intended Xcode version.
- Verify the app bundle contains the MP3 helper, LAME license/source/recipe and all three localized privacy prompts.
- Existing 0.1.x `session.json`, moved folders and duplicate nested folder names load and export correctly.

## Disposable hardware acceptance

Record device models, OS/Xcode versions, commit, elapsed duration, peak resident memory, file duration and observed result. Use synthetic/consented audio and a temporary storage root, never real user recordings.

| Scenario | Acceptance evidence |
| --- | --- |
| Clean browser-downloaded install | Valid Developer ID signature and stapled ticket; Gatekeeper passes; no quarantine removal |
| Permissions in EN/JA/KO | Deny then grant microphone/app/storage; imports remain usable; system prompts use the selected OS language |
| Zoom, Teams, Meet | At least 10 minutes per app with a wired headset; audible isolated channels and usable transcription |
| Two-hour meeting | Compare source and output duration within 1 second; no unexplained silence; record CPU, peak RSS and energy use |
| Built-in mic | Mono fallback is clear; transcript labels do not imply separate people |
| Bluetooth and device unplug | Hot switch does not pitch-shift audio; failure visibly stops and preserves recorded frames |
| Forced sleep / wake | Recording stops and saves; no active timer remains while input is gone |
| SIGKILL during capture | Next launch recovers complete audio frames and does not overwrite the original |
| Low disk / denied write | Recording stops visibly; recovery works after space/access is restored |
| Quit during capture | Cancel keeps recording; Save and quit preserves the file |
| Restart during transcription | Pending state reloads, work reruns, previous notes/bookmarks remain |
| Concurrent GUI launch | Second writer is refused; live recording header remains unchanged |
| Replace file in Finder | Watcher invalidates playback, refreshes transcript and search |
| Selected-range export | Audio range matches boundaries; Markdown includes notes and only in-range bookmarks |
| Update tampering | Reject wrong digest, size, bundle ID, version, Team ID, signature and missing notarization |
| Failed replacement | Previous app restored; recordings and settings remain accessible |
| Keyboard / VoiceOver | Import, recording stop, notes, transcript playback and bookmarks are reachable at small window sizes |

Performance targets for the two-hour test: application peak RSS below 500 MB, no unbounded growth between the first and second hour, and no lost audio under normal system load. These are acceptance targets, not measurements already obtained.

## Signing and packaging

Use your own Apple Developer membership and Developer ID Application certificate. Store notary credentials in Keychain, for example with `xcrun notarytool store-credentials`; no credentials go into git.

```bash
export RYOKUON_SIGN_IDENTITY='Developer ID Application: your publisher (TEAMID)'
export RYOKUON_NOTARY_PROFILE='your-keychain-profile'
bash Scripts/make_release.sh --notarize
```

This validates, builds, notarizes, staples and creates `.build/Ryokuon.zip`, `.build/Ryokuon.dmg` and a ZIP checksum. `--publish` also adds the DMG checksum and creates a **draft** GitHub release. First increment `CFBundleShortVersionString` and `CFBundleVersion`; never reuse an existing tag. Ad-hoc/Apple Development identities cannot pass the production packaging gate.

Before making the draft public:

1. Complete hardware acceptance and attach actual app screenshots using fictional data.
2. Put the verified Apple Team ID and minimum macOS/architecture in release notes.
3. Download the release via a browser onto a clean Mac and validate the stapled DMG/app.
4. Check both ZIP and DMG against `SHA256SUMS` and ensure the GitHub ZIP asset has a `sha256:` digest.
5. Test upgrade from an existing release. Older development-signed builds may require manual replacement by the first notarized release.
6. Publish the reviewed draft. No script removes quarantine or disables Gatekeeper.

The optional installer requires `RYOKUON_TEAM_ID` copied from verified publisher documentation. Do not teach users to guess it or bypass this check.
