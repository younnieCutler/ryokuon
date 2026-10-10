# Ryokuon

A native macOS meeting recorder with on-device transcription. Record a call, review the transcript, and export audio or Markdown without uploading your conversations to a transcription service.

[日本語](README.ja.md) · [Releases](https://github.com/younnieCutler/ryokuon/releases) · [Report a problem](https://github.com/younnieCutler/ryokuon/issues/new/choose) · [Contributing](CONTRIBUTING.md)

**Pre-1.0.** This branch hardens interaction, long-recording handling, data protection and distribution. It is not a claim of completed hardware or GUI validation. The existing v0.1.3 binary predates these changes; see the [release gates](docs/RELEASE_READINESS.md).

## What it does

- Capture your microphone and one explicitly selected app. Headset recordings separate you and the remote side into left/right channels; built-in microphone recordings are mono to account for speaker bleed.
- Transcribe Japanese, Korean and English using Apple's `SpeechAnalyzer`. Automatic language selection is heuristic; override it when needed.
- Browse real folders, open a recording in one click, search renamed sessions, pause and resume, and jump back or forward ten seconds.
- Click transcript timestamps to seek; select text without starting playback. Copy the displayed transcript (including search results) from the toolbar. Turn off playback-following while reading; searching does not pull you back to the playhead.
- Import M4A, MP3, WAV or FLAC. Choose an export folder, set precise range boundaries, and explicitly confirm replacing existing files.
- Move recordings to Finder's Trash, with confirmation. Active recording/processing prevents app termination, removal and storage changes.

Audio input for playback and full transcription is read in bounded chunks. Transcript words still accumulate in memory; unusually long sessions need the profiling in the release checklist.

## Requirements

Apple silicon, macOS 26 or later. Source builds require Swift 6.2 or newer and a macOS 26 SDK. The UI supports Japanese, Korean and English.

Microphone, app-audio capture and folder permissions are needed to record. You can defer recording permissions and import an existing file instead. Initial speech-model downloads require internet access.

## Install

Use a **signed, notarized release** when one is available. The public installer validates the app signature, bundle identity and Gatekeeper assessment; it refuses to replace a running app. The currently published v0.1.3 artifact is not evidence that these release requirements are met. Until the next notarized release, use a source build.

```bash
curl -fsSL https://raw.githubusercontent.com/younnieCutler/ryokuon/main/install.sh | bash
```

Updates can be checked from Settings. Downloaded updates require the expected SHA-256, app identity, version, signing team and Gatekeeper assessment. Close the app before running the command-line installer or uninstaller.

## Everyday use

1. Play audio in the call app, select that app in Ryokuon, and press Record. Selecting a target does not itself start capture. If an explicitly selected process disappears, Ryokuon does not silently record another app.
2. Stop recording to queue transcription. A queued transcription can be cancelled; an active transcription must finish before quitting.
3. Select the recording folder directly to read the transcript. Play/Pause preserves position. Adjusting stereo gains changes playback and subsequent exports/transcription, without altering the original audio.
4. Export a full recording or range. Outputs go to the chosen folder; existing names require confirmation. MP3 and Markdown are individually protected writes, not a single multi-file transaction.

| Shortcut | Action |
| --- | --- |
| Arrow keys | Navigate folders and recordings |
| Delete | Confirm moving the selected recording to Trash |
| Command-O | Import audio |
| Command-comma | Settings |
| Command-1 | Open the library window |
| Command-Shift-R | Start/stop the selected recording target |
| Command-R | Refresh the library |
| Command-Return | Play/pause the selected session |
| Command-Shift-E | Open session export |

Playback/export shortcuts apply when their controls are available. Recording requires the relevant permissions.

## Your data

The default root is `~/Documents/ryokuon`. Settings can change it. Organize recording folders beneath the selected root in Finder; Ryokuon reads nested folders and detects changes.

| File | Purpose |
| --- | --- |
| `call.wav` / `call.flac` | Recording; successful conversion verifies FLAC before removing WAV |
| `transcript.txt` | Timestamped utterances, with M/R/U speaker tags |
| `raw.json` | Recognized words and confidence values |
| `session.json` | Display name, language, duration and gains |

Audio and transcripts are processed locally. Apple model downloads and GitHub update checks use the network. There is no analytics SDK in this repository. Sharing exports, issue attachments or a synced storage folder is your explicit choice. See [privacy and security](SECURITY.md).

## Build and validate

```bash
brew install lame
swift build
swift test
swift test --sanitize=thread
export RYOKUON_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
bash Scripts/bundle.sh
open .build/Ryokuon.app
```

Run the synthetic Japanese/Korean/English speech integration checks with `RYOKUON_SPEECH_E2E=1 swift test --filter SpeechPipelineIntegrationTests`. This installs Apple speech assets and uses temporary generated audio.

Use a temporary storage root for E2E, never real meeting recordings. The [validation guide](CONTRIBUTING.md) describes the defaults override and safe restoration. CI uses macOS 26 and retains build/test logs; a CI pass cannot validate real call capture, TCC dialogs, accessibility or notarized update installation.

CLI helpers are in `bin/ryokuon` (`list`, `show`, `search`, `range`). Use relative paths printed by `list`, including parent folders.

## Public release

Publishing requires a Developer ID Application certificate and a `notarytool` keychain profile. The release script submits for notarization, staples the app, validates it and only then publishes. Credentials are never committed. See [release readiness](docs/RELEASE_READINESS.md).

No release is approved merely because source changes are merged. Licensing, hardware tests, GUI evidence and signed distribution remain explicit release gates.

### Cancelling and recovering work

Cancel an active transcription from its session detail or remove a queued transcription before it starts. The import activity row can cancel the current import and all pending imports. Wait for cleanup to finish before quitting; completed imports and source recordings are retained.

If session metadata is damaged, open its folder in the library. The warning explains how to play the remaining audio or import it as a new session. Ryokuon does not overwrite the damaged metadata automatically.
