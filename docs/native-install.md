# Installation, preview and restore

Use the complete extracted binary package and double-click `Start.cmd`. **Check** (also Enter) is passive. **Install** previews the per-user registration and requests the exact word `INSTALL` before applying it. **Restore** previews recovery and requests `RESTORE`. The console keeps errors visible. It does not offer a force test, launch Bridge, or Arm the joystick. No compiler or source checkout is needed.

Close FFB-Bridge fully, X-Plane and diagnostic applications before Install or Restore. Apply requires the [exact eligibility gates](../README.md), a valid release manifest, unchanged allowlisted files and the expected x64 DLL. The package directory is validated as a complete inventory: keep unrelated files and generated reports outside it. Do not edit the manifest or suppress a compatibility refusal.

The same explicit actions are available from native 64-bit Windows PowerShell in the extracted folder:

```powershell
.\tools\Start-SaitekFfbSetup.ps1 -Action Check
.\tools\Start-SaitekFfbSetup.ps1 -Action Install -WhatIf
.\tools\Start-SaitekFfbSetup.ps1 -Action Install
.\tools\Start-SaitekFfbSetup.ps1 -Action Restore -WhatIf
.\tools\Start-SaitekFfbSetup.ps1 -Action Restore
```

Noninteractive Install/Restore are explicit instructions to perform the action; `-WhatIf` previews without mutation. The lower-level installer accepts `-Mode Apply -ReleaseManifest .\release-manifest.json` or `-Mode Restore`. Development builds instead use `-ArtifactManifest` and strict current-source checks. Those two manifest inputs are mutually exclusive. The source build path uses `tools/Build-Driver.ps1` with the existing Visual Studio C++ tools and Windows SDK.

Apply stages the DLL in content-addressed per-user storage under `%LOCALAPPDATA%\SaitekNativeFfb\bin` and changes only native Registry64 `HKCU\Software\Classes\CLSID\{1DB0C28F-6D99-416E-8D05-73DE59E6E170}` plus the exact device's `OEMForceFeedback` subtree. Its eight implemented effects and eight compatibility masks are included in the backed-up transaction. Machine registration, system files, HID input binding, axes and calibration are preserved. OEM force-feedback metadata is shared across bitness; this x64-only class does not preserve a previous x86 FFB application's routing while the override is active.

The compatibility masks rely on the inspected Windows DirectInput reader skipping zero-coordinate entries; this is implementation-specific. The exact `dinput8.dll` hash in [README](../README.md) remains required. A Windows update can block Apply. Restore remains available independently of the current Windows fingerprint.

Before target changes, the installer saves typed registry values, original tree existence, owner SID, exact target paths and binary identity under `%LOCALAPPDATA%\SaitekNativeFfb\backups`. An active different build or incomplete transaction blocks another installation. A repeated Apply of the same active configuration preserves its original backup. Write failure attempts automatic rollback and reports incomplete recovery if it cannot finish.

Restore uses the saved owner-bound transaction without the source checkout, current release manifest or current DLL matching the installed version. Keep the installer and its `SaitekFfb.Common.ps1` together. It restores original value types/content and tree absence, removes only newly created empty ancestors, and removes staged bytes only if they still match. Modified staged bytes are retained and reported. Backup records and empty storage directories remain for recovery; registry ACLs are not exported. Keep backups private.

Restore requires exactly one active transaction. The lower-level installer accepts `-Mode Restore -BackupId 'the-id-returned-by-Apply'` to identify that transaction, but an explicit ID does not bypass the sole-active requirement. If multiple active records require attention, stop and [open a recovery issue](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/issues) with a reviewed support report; do not edit or delete backup files or upload their contents. A legacy repair transaction requires the original legacy Restore tool and its original backup. The vendor-dependent repair flow is excluded from this package; recover that transaction with the retained original tool before applying this driver.

Upgrade is **Restore the old transaction, then Apply the new complete package**. Do not replace an active staged DLL manually. After a successful install, follow [the intentional flight guide](flying.md); software success does not assert physical force correctness.
