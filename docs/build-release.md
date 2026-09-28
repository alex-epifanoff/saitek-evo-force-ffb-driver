# Build, check and release

Use a native **64-bit Windows PowerShell 5.1** session on Windows with existing Visual Studio C++ x64 tools, the Windows SDK and Git available. `tools/Build-Driver.ps1` locates MSVC through `vswhere.exe` and enters its x64 development shell. It does not install a compiler or SDK. No joystick, Bridge installation or simulator is needed for the offline build.

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Driver.ps1
```

This builds `out\driver\SaitekFfbDriver.dll`, runs the COM contract and HID PID protocol/transport suites, and writes `out\driver\build-manifest.json` with actual source/test hashes and toolchain identity. A failed build removes the previous manifest. A `-SkipTests` build is unsuitable for packaging; the package builder requires both offline test results.

Run the shared local/Actions checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-CI.ps1 -Version '0.1.0-alpha.2'
```

`tools/Invoke-CI.ps1` always runs the native build and its offline suites, owner-tool tests, and package tests with `-RebuildExport`. The export test builds the exported source to check its completeness. The installer suites run only when the host's native `dinput8.dll` has SHA-256 `B0F10001FCCD05E9863D84588BE9B9F8389656D95177287DD4C6CF3BE4BF1DFE`. On other hosts the runner records an explicit **SKIP** for those suites, including ordinary hosted runners whose Windows image does not match. A skip is not a passed installer test. Production compatibility guards remain unchanged; do not replace the expected hash or weaken validation to make CI green.

These checks do not open joystick hardware, launch Bridge, Arm the device or establish physical acceptance. Installer fixtures use isolated test state. The result summary is written to `out\ci\verification-summary.json`; it is separate from the release package inventory.

To assemble release artifacts as well, use a clean committed checkout and a version whose output directory does not already exist:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-CI.ps1 -Version '0.1.0-alpha.2' -Package
```

The runner also accepts a strict `v0.1.0-alpha.2` tag as its version. Packaging calls `tools/Build-Release.ps1`, which accepts the unprefixed version and exports only `release/release-spec.json`'s exact allowlists. It verifies the current build and clean source identity, rejects stale evidence and refuses to overwrite an existing version directory. Artifacts under `out\release\0.1.0-alpha.2\` are:

- `SaitekNativeFfb-0.1.0-alpha.2-win-x64.zip`
- `SaitekNativeFfb-0.1.0-alpha.2-source.zip`
- `release-manifest.json`
- `SHA256SUMS.txt`
- `verification-summary.json` (added and checksummed by the CI runner; kept outside both ZIP payloads)

The source ZIP preserves `release/import-origin.json` unchanged as historical import evidence. It does not identify the current build. The generated `source-identity.json` and release manifest describe the current export. The import-origin file is excluded from the binary ZIP.

The [CI workflow](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/actions/workflows/ci.yml) runs on main-branch changes, pull requests and manual dispatch. The [release workflow](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/actions/workflows/release.yml) runs on `vX.Y.Z-alpha.N` tags or manual dispatch for an existing alpha tag. It checks out that tag, uses the shared runner, and creates an **Actions-built draft prerelease** with the two ZIPs, manifest, checksums and verification summary. It does not publish the draft automatically.

Before publishing, the maintainer reviews [Actions](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/actions), actual passed/skipped checks, the artifact inventory and manifests, notices, and outstanding pilot/redistribution checks. Publish the reviewed draft through [Releases](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/releases). Keep unverified artifact/effect behavior, reconnect and second-PC acceptance explicit in its notes. A source or documentation change requires a fresh build and new release identity.

Project code uses the [MIT License](../LICENSE), copyright 2026 Alex Epifanov. Third-party materials retain their own terms, and static MSVC runtime redistribution review remains open before maintainer publication. The unsigned SHA-256 files detect changed bytes but do not authenticate a publisher. See [release status](../release/RELEASE-STATUS.md), [provenance](../release/PROVENANCE.md) and [third-party notices](../release/THIRD-PARTY-NOTICES.md).
