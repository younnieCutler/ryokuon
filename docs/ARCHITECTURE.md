# Architecture

Ryokuon is a SwiftPM executable with a native SwiftUI/AppKit interface and no backend service. macOS 26 SpeechAnalyzer supplies on-device recognition.

## Recording

A CoreAudio process tap and a selected microphone feed an aggregate device. The real-time callback mixes into preallocated rings; a serial writer queue drains every 200 ms, converts to 16 kHz PCM and writes `call.wav`. Ring overflow and write failure stop capture through the main-actor coordinator instead of silently continuing. The writer syncs approximately every five seconds; power loss can still lose data not committed by the filesystem.

WAV creation is exclusive: existing files cannot be overwritten. A finalized header and session state are saved on normal stop. Recovery validates the expected fixed PCM header, retains complete frames, removes only an incomplete tail and marks the session recovered. A process lease prevents a second GUI/developer writer from recovering a file during live capture. These mechanisms protect recoverability, not a claim of zero-loss recording.

Recording holds an idle-sleep activity, checks available capacity before start and every ten seconds, and stops on forced system sleep. Quit asks to stop and save active capture; imports and exports must finish before quitting.

## Persistence and background work

`SessionStore` treats the actual folder location as authoritative. Metadata contains a stable folder ID; its root-relative path is derived when scanned. This supports project subfolders and duplicate leaf names. Mutation reloads fresh metadata, changes only the requested fields and publishes a successful atomic save.

Transcription state is persisted as `notStarted`, `queued`, `transcribing`, `completed` or `failed`. An interrupted `transcribing` job becomes queued on restart and runs from the beginning. Failed jobs retain their error and wait for manual retry. This is durable job scheduling, not word-level incremental resumption. Legacy metadata loads with empty notes/bookmarks and `notStarted`.

Import and export workers use detached utility tasks. Per-session ownership prevents export/deletion during an active writer; changing roots waits for all work. Closing the app during transcription is safe for the audio but restarts that job on the next launch.

## Long recordings

Playback queues at most two five-second buffers and seeks the source file. Recognition of separated tracks writes one temporary mono FLAC in ten-second chunks, then uses SpeechAnalyzer's file input API. Recognition text is retained in memory; audio PCM memory does not scale with meeting duration. Export and FLAC conversion also stream chunks. Language detection uses a bounded thirty-second probe.

Search indexes transcript/notes/title/app/bookmarks off the main actor. A revision check prevents old-root results from replacing a newer index. The index currently rebuilds for each coalesced library change and lives in memory; a database-backed index is a future optimization if large-library measurements warrant it.

## Delivery boundary

Development CI uses ad-hoc signing. Production release tooling requires a Developer ID Application identity, validates tests, notarizes and staples both the app and DMG, creates checksums, then prepares a draft GitHub release. Publishing and hardware acceptance remain explicit maintainer steps. Network traffic is limited to model downloads and manual updates in the product; build tooling also retrieves pinned LAME sources.
