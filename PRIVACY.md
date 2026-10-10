# Privacy

Ryokuon records your microphone and the application you explicitly select. It does not upload recordings, transcripts, notes or bookmarks, and has no account, advertising SDK or product analytics SDK.

Apple's SpeechAnalyzer runs recognition on-device. The operating system may download speech models and keep them updated. Automatic language detection can download models for Japanese, Korean and English; select a language manually to avoid probing all three. Model distribution is handled by Apple.

Checking for updates is manual. It sends a request to GitHub's public release API and downloads the chosen release from GitHub. GitHub receives ordinary network request information such as an IP address. Ryokuon does not include meeting content in these requests.

Recordings, recognition results and metadata are ordinary files under your chosen storage root. This release does not provide app-level encryption or a sandbox. Use FileVault, appropriate folder permissions and your organization's approved backup policy. Choosing an iCloud/Dropbox/shared folder can cause that external service to sync files; that behavior is controlled by your folder choice and that service.

Transcription of separated tracks creates one temporary lossless channel file alongside the session, then removes it on normal completion or failure. A forced process kill may leave that temporary file. It contains meeting audio and belongs in the same backup/deletion policy as the recording. Uninstalling the app preserves recording folders. Deleting a session removes its entire folder, including notes and exports.

Capture errors appear in the UI and can include local file paths. The updater's local log is `~/Library/Logs/Ryokuon-update.log`. Review and redact logs before sharing. No crash report submission service is integrated.

Tell meeting participants before recording and follow your employer's recording policy. Review speech recognition output before using it as an authoritative record.
