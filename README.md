# Ryokuon

Local-first macOS utility for recording two-person calls into separate ME/REMOTE
tracks, transcribing them on-device, and browsing the transcript alongside
playback — no cloud, no external services.

- Separately captures your microphone and one chosen app's audio output into
  a single stereo `call.wav` (L=me, R=remote), sample-aligned via a private
  CoreAudio aggregate device.
- Transcribes both channels on-device with Apple's `Speech.framework`
  (`SpeechAnalyzer`/`SpeechTranscriber`), merges words into utterances, and
  writes a compact `startMs|speaker|text` transcript.
- Converts to FLAC after transcription and deletes the original WAV.
- Native SwiftUI window (NavigationSplitView: session list, transcript,
  compact player with per-track gain) plus a menu bar status item.

## Build

```bash
export RYOKUON_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
# find yours with: security find-identity -v -p codesigning
bash Scripts/bundle.sh
open .build/Ryokuon.app
```

## Test

```bash
swift test
```

## Author

Jeongyun Kim — ehrktm090@gmail.com
