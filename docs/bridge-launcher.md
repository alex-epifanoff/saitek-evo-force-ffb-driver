# Optional Bridge launcher

Install Bridge separately from the [official FFB-Bridge site](https://ffb-bridge.com/). This package does not include, modify or download its installer, assemblies, configuration or bundled .NET runtime.

The supplied launcher requires EXE and DLL file versions **1.5.3.0**, `net10.0`, exactly one included `Microsoft.NETCore.App` **10.0.12**, and CoreLib SHA-256 `1125ACC8106C43FC8BAD2D203C4C4485DF6182D292846C2FFF415C1040C54678`. It refuses missing/changed identities and refuses any existing `FfbBridge*` process. Fully exit Bridge, including its tray icon, before starting a new session. Do not remove the guards to run another build.

Double-click `Start.cmd`, choose **Create Bridge shortcut**, review the destination and type `CREATE`. The helper suggests the desktop but never changes it automatically or replaces an existing shortcut. If the default separate Bridge installation is absent, the console asks for its folder. Keep the extracted package in place after creating the shortcut; if moved, create a new shortcut to the moved package. Shortcut creation does not launch Bridge.

For an explicit destination, from native PowerShell in the package directory:

```powershell
# Preview only; choose an existing destination folder and a new filename.
.\tools\New-SaitekFfbShortcut.ps1 -DestinationPath "$env:USERPROFILE\Documents\Saitek FFB-Bridge.lnk" -WhatIf
# Use a nondefault separate installation when necessary.
.\tools\Start-SaitekFfbBridge.ps1 -BridgeDirectory 'C:\Apps\ffb-bridge' -WhatIf
# Default official per-user location; launching never Arms the device.
.\tools\Start-SaitekFfbBridge.ps1
```

The default Bridge location is `%LOCALAPPDATA%\Programs\ffb-bridge`. `-BridgeDirectory` selects another existing installation without weakening identity checks. The shortcut quotes paths with spaces and keeps the PowerShell window open so a launch refusal remains visible.

The workaround sets `DOTNET_ThreadPool_ThreadsToKeepAlive=-1` and `DOTNET_ThreadPool_UseWindowsThreadPool=0` only in the launched process. It retains the worker owning the inspected Bridge build's hidden control window, avoiding the observed idle-window lifetime failure. It changes neither global environment variables nor Bridge files/settings, and it never kills an application. It serializes this launcher's check/start pair and retains Bridge's own instance behavior.

The earlier owner session passed delayed Arm, Disarm and rearm checks, but that does not establish reliability across PCs or updates. This remains a bounded workaround requiring review after any Bridge/runtime change. Arm and Disarm remain deliberate owner actions; see [first flight](flying.md).
