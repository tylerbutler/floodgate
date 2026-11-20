# floodgate changelog

## v0.2.0 - 2026-11-20

### Changed

- Remove the client release PR, tagging, and npm publishing pipeline; keep the client workspace and compatibility tests.
- Upgrade Beryl to 0.6.0, its Mist adapter to 0.4.1, and Dewdrop to 0.2.0. Preserve socket write error details and report PubSub startup and presence update failures.
- Use Trellis for Gleam tasks, server changelogs, and release PRs; retain Just for repository coordination.

### Fixed

- Keep presence snapshots and diffs in channel queue order when using Beryl 0.6.
- Recover acknowledged summary versions and enforce document-owned published history.
