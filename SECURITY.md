# Security policy

Report vulnerabilities privately to ehrktm090@gmail.com with the affected version, reproduction steps and impact. Do not attach real customer recordings or credentials. Avoid publishing exploit details in a public issue before the maintainer can respond. No response-time SLA is promised.

Pre-1.0 builds are under active development. Please reproduce on the latest code. Production distributions must use Developer ID Application signing, Apple notarization and a stapled ticket. Do not disable Gatekeeper or remove quarantine attributes to work around an installation failure.

The updater verifies release location, SHA-256 and asset size, bundle identifier, version, code signature, publisher Team ID and notarization before replacement. The optional shell installer requires a publisher Team ID that the user verifies from release documentation. Distribution credentials belong in the macOS Keychain, never in source control.
