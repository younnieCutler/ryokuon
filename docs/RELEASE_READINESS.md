# Release readiness

## Status of this change

Implementation was authored on Linux. Code commit `80f900d39c41e9be8f625b2d20b4461263618dad` passed [macOS CI](https://github.com/younnieCutler/ryokuon/actions/runs/37954196120) on macOS 26.6.2:

| Check | Result | Toolchain |
| --- | --- | --- |
| Debug build, warnings treated as errors | Passed | Xcode 26.2 |
| 73 tests in 21 suites | Passed | Xcode 26.2 |
| Release build | Passed | Xcode 26.2 |
| Full Thread Sanitizer run, 73 tests | Passed | Xcode 26.6, isolated build directory |
| Shell syntax and whitespace checks | Passed | macOS runner |

The earlier Xcode 26.2 sanitizer execution exited with signal 11 before tests ([failed run](https://github.com/younnieCutler/ryokuon/actions/runs/37953800502)); changing the sanitizer toolchain and isolating build output resolved execution. The exact cause of that startup failure is not established. No custom sanitizer suppression or failure bypass was added.

GUI behavior, audio listening, speech-model execution and notarized distribution remain unverified. Do not treat the v0.1.3 artifact or older PR #1 report as validation of this branch. Documentation-only commits after the validated code do not change the tested implementation.

## Implemented

- Arrow-key tree navigation, confirmed keyboard deletion, selectable transcript text and a copy action.
- Native list selection and direct opening of session folders; renamed titles are primary.
- Folder detail browsing, whitespace-normalized search, no-results feedback and Finder reveal.
- Pause/resume, ten-second navigation, EOF-safe seek, live saved gains and output changes.
- Bounded playback scheduling and demand-driven full-transcription audio input.
- Optional transcript following, explicit rename save, cancellation of active/queued transcription and import batches.
- Damaged session metadata guidance preserves source files and keeps audio browsable.
- Precise export boundaries, destination selection and overwrite confirmation.
- Trash-based session removal using full relative identity, not duplicated folder basenames.
- Deferred recording permissions, permission-recovery guidance, Dock/Command-Tab presence.
- Fresh menu-bar targets, no automatic replacement of a lost explicit target, busy quit guard.
- RIFF boundary rejection rather than integer overflow; failed capture preserves a recovered partial session.
- macOS CI, regression tests, issue forms and public distribution notarization gates.

## Required before public release

- [ ] Exact release commit passes debug build, tests, Thread Sanitizer and release build. Review skipped tests and retained logs.
- [ ] Listen to both sides of live calls with built-in and USB/stereo microphones. Check duration, channel alignment, no clipping and long-session memory.
- [ ] Test unplug, sample-rate switch, failed start/write, storage full, crash/relaunch and partial recording recovery.
- [ ] Test three-language transcription, wrong-language retry, no-speech input and first-model download.
- [ ] Validate streamed transcription timestamps/content and resampling at chunk boundaries with representative long recordings.
- [ ] Exercise pause/resume, EOF seek, gain changes and default/manual output switching by listening.
- [ ] Exercise all export formats, destination denial, overwrite cancel/confirm, partial multi-file failure and MP3 boundary listening.
- [ ] Verify keyboard navigation, small windows, light/dark mode, VoiceOver and reduced-motion settings. Capture real screenshots/GIFs for the README.
- [ ] Verify Trash restore, nested duplicate names, processing deletion guards and quitting/updating during work.
- [ ] Sign with Developer ID Application, notarize, staple, validate with Gatekeeper, then test installation/update on a clean Mac. Keep the same signing team for updates.
- [ ] Choose and commit an explicit project license; review bundled LAME license/source obligations. No license grant is invented by this change.

## Distribution

Local signed development builds still use `Scripts/bundle.sh`. Public publishing is gated:

```bash
export RYOKUON_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export RYOKUON_NOTARY_PROFILE="your-keychain-profile"
bash Scripts/make_release.sh --publish
```

Increment Info.plist only for a validated release. Do not store certificates, account passwords or signing keys in the repository. The public installer on this branch rejects old unnotarized artifacts by design; publish the new verified artifact before advertising the updated installation path.

## Remaining product limits

- Active transcription, queued jobs and import batches support cancellation. Cleanup keeps the busy guard until workers finish; a conversion already committed may remain completed.
- Recognition words/results still accumulate in memory even though audio input is streamed.
- WAV recording stops at the RIFF size limit; automatic file rotation is not implemented.
- MP3 and Markdown are staged together; publication errors roll back previous exports. Failed rollback retains backups and a recovery map. A process crash during multi-file renames still requires manual recovery from the staging directory.
- Mixed-language recognition and robust speaker diarization are not guaranteed.
- Automatic language choice is a confidence heuristic; imported audio is mono.
- Damaged metadata is identified in folder details; audio can be opened or imported into a new session. Original metadata is not automatically reconstructed. Sample-rate/device hardware fault coverage remains a follow-up.

## Adoption target

The 1,000-star goal is an adoption target, not a correctness metric or a promised result. Ship only after these gates, demonstrate a real meeting-to-Markdown workflow, make privacy and limitations clear, and use bug reports to prioritize the next iteration. Avoid expanding features before reliability is demonstrated.
