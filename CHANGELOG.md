# Changelog

## 0.1.0-alpha.2

- Prepare the public experimental alpha with installation, Restore, Bridge and issue-reporting guides.
- Add Windows CI for the native build, offline owner-tool checks and package export/rebuild checks. Installer suites run only on the exact pinned Windows DirectInput host; other hosts explicitly report a skip.
- Build draft prereleases from `vX.Y.Z-alpha.N` tags through GitHub Actions, with binary/source ZIPs, a release manifest, SHA-256 checksums and a verification summary for maintainer review.
- Preserve the historical source import inventory as `release/import-origin.json` in source exports; current builds have separate source identity evidence.
- Keep exact device, DirectInput and optional Bridge/runtime guards, manual Arm, sole-active Restore and restore-before-upgrade behavior.

The owner reports FFB working in X-Plane 12 on their setup. The report does not identify an exact release artifact or verify individual effects, reconnect recovery or a second PC.

## 0.1.0-alpha.1

Private evaluation package with original x64 driver source, per-user installation and Restore, passive support reporting, an optional process-scoped Bridge launcher, and offline validation. Earlier owner observations established useful centering; broader physical acceptance remained open.
