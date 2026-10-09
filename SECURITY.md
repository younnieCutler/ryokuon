# Privacy and security

Recordings, transcripts and recognition results are stored in the selected folder. Recognition uses Apple's on-device speech modules; model installation may contact Apple. Update checks/downloads contact GitHub. The source contains no telemetry SDK or hosted transcription client.

This does not encrypt the selected folder. A cloud-synced folder, exported file or screenshot can expose conversations outside the app. Use your organization's approved storage and recording policy.

Session metadata is validated against its folder. Symlinked library entries are excluded. This is not a general defense against a hostile process modifying the filesystem concurrently.

Updates verify SHA-256, bundle identity, version, signing team and Gatekeeper assessment. Public releases require notarization. Installer updates refuse a running app. Do not disable these checks to make a public release installable.

Report vulnerabilities privately to the maintainer at ehrktm090@gmail.com (listed in the repository's original README). Do not include live recordings, transcripts or credentials. Public bug reports should use synthetic examples and redact personal information.
