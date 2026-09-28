# Contributing

Use [Issues](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/issues) for reproducible failures and proposed changes. Include the release version, relevant exact software versions, expected behavior, actual behavior and reproduction steps. Review any support JSON before sharing it. Do not post registry backups, account/device identifiers, proprietary binaries or raw private captures.

Changes must preserve the exact-device and software identity guards unless evidence and a separately reviewed compatibility change justify expanding support. Keep installation and support passive with respect to hardware. Arm stays manual; upgrades restore the old transaction first; Restore still requires exactly one active transaction. Do not bypass a production guard to make a test pass.

Use native x64 Windows PowerShell 5.1 with existing MSVC C++ tools and the Windows SDK. Run `tools/Invoke-CI.ps1` as described in [build and release](docs/build-release.md), and report explicit skips as skips. Offline success cannot establish physical effect quality, reconnect behavior or acceptance on a second PC. Describe any intentional physical test separately, including which artifact was used.

Keep pull requests focused and state the observed problem, changed behavior and validation. Preserve source/archive allowlists and update affected documentation. Do not add vendor driver code, binary patches, research source copies, Bridge assemblies, SDK files, credentials or private evidence to the repository or release payload.

Project code uses the [MIT License](LICENSE), copyright 2026 Alex Epifanov. Identify the provenance and terms of any proposed third-party code; the project license does not replace those terms. See [provenance](release/PROVENANCE.md) and [third-party notices](release/THIRD-PARTY-NOTICES.md).
