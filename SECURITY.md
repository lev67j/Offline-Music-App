# Security Policy

## Supported version

Security fixes are applied to the latest revision of the `main` branch.

## Reporting a vulnerability

Please use GitHub's **Security → Report a vulnerability** flow so the report and any proof of concept remain private. Do not open a public issue containing credentials, device tokens, OAuth tokens, personal library metadata, private URLs, or user audio.

Include the affected revision, expected and observed behavior, reproduction steps, and the smallest safe proof of concept. Reports involving data loss, authorization bypass, path traversal, credential exposure, or remote code execution receive priority.

## Data-loss guarantees

Offline Music treats the on-device library as canonical. Persistence uses validated atomic writes and rotating backups. Damaged metadata and cloud-driven removals are quarantined, and unusually destructive cloud snapshots are blocked before they can replace the local library.
