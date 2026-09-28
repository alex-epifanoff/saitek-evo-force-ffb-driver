# Saitek Cyborg Evo Force FFB driver

An x64 Windows DirectInput effect driver for the exact Saitek Cyborg Evo Force USB `06A3:FFB5` device and validated HID PID descriptor. **Version 0.1.0-alpha.2 is an unsigned experimental alpha.** It preserves ordinary HID joystick input and has a narrow compatibility scope.

The owner reports that force feedback works in **X-Plane 12 on their setup**. The exact artifact and effect behavior behind that report have not been established. An earlier session established useful centering. This is not verification of this release package, every advertised effect, reconnect recovery, a second PC or general compatibility.

[Download prereleases](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/releases) · [Build results](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/actions) · [Report an issue](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/issues) · [Changes](CHANGELOG.md)

Extract the entire `SaitekNativeFfb-0.1.0-alpha.2-win-x64.zip` to a folder you can keep, then double-click **Start.cmd**. The console offers Check, Install, Restore, Support report, Create Bridge shortcut, and Exit. Pressing Enter performs a passive Check only. Installation previews its changes and requires you to type `INSTALL`; it never launches Bridge or Arms the stick. No compiler, source checkout, administrator account, or command/path edits are needed for the binary package.

Before installation:

- Use native x64 Windows, the exact supported joystick, and the Windows `dinput8.dll` identity below. Other models, descriptors and Windows binaries are not supported by this alpha.
- Obtain FFB-Bridge separately from its [official site](https://ffb-bridge.com/). This package contains no Bridge installer or assemblies. The optional launcher requires exactly Bridge **1.5.3.0**, bundled .NET **10.0.12**, and the pinned CoreLib hash.
- Close Bridge completely, including its tray icon, X-Plane and diagnostic applications. If a previous native installation is active, **Restore it before changing builds**. An active legacy repair transaction requires its original recovery tool and backup; that vendor-dependent flow is excluded here.
- Read [eligibility and limits](docs/community-alpha.md), [installation and restore](docs/native-install.md), and [first intentional flight and stop](docs/flying.md). In Bridge, device selection is under **Hardware → Device** and effect settings are under **Hardware → Effects**. Arm remains a deliberate user action.

Check and Support report are passive: no HID/DirectInput access, probe, Bridge launch or upload. Reports omit identity, raw paths and registry content; review the JSON before sharing it in an issue. Check does not validate the physical descriptor or certify force behavior. Install performs the complete package validation separately.

Keep the extracted folder for the optional shortcut. The launcher applies only process-scoped settings, refuses an existing Bridge process, and leaves Arm/Disarm to the user. See [launcher details](docs/bridge-launcher.md). Restore remains available after a Windows update or without the original source/build manifest, using the saved per-user transaction and the provided installer. There is no automatic reconnect or replay of effects.

| Compatibility gate | Exact identity |
| --- | --- |
| Device | USB VID `06A3`, PID `FFB5`, validated HID PID layout |
| Driver/application | x64 DirectInput; x86 force feedback is not provided |
| Windows DirectInput | `dinput8.dll` observed version `10.0.26100.8457`; SHA-256 `B0F10001FCCD05E9863D84588BE9B9F8389656D95177287DD4C6CF3BE4BF1DFE` (installer hash guard) |
| Optional Bridge launcher | EXE and DLL file versions `1.5.3.0`, `net10.0`, included `Microsoft.NETCore.App` `10.0.12` |
| Bundled CoreLib | SHA-256 `1125ACC8106C43FC8BAD2D203C4C4485DF6182D292846C2FFF415C1040C54678` |

Developers can build with native Windows PowerShell 5.1, existing Visual Studio C++ tools and the Windows SDK. See [build and release instructions](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/blob/main/docs/build-release.md), [contributing](https://github.com/alex-epifanoff/saitek-evo-force-ffb-driver/blob/main/CONTRIBUTING.md), [runtime behavior](docs/native-driver.md) and [protocol notes](docs/protocol.md). Actions creates draft prereleases for alpha tags; a maintainer reviews the checks before publication. Offline checks do not establish physical acceptance.

Project code is available under the [MIT License](LICENSE), copyright 2026 Alex Epifanov. The binary package includes `PROVENANCE.md`, `RELEASE-STATUS.md` and `THIRD-PARTY-NOTICES.md` (under `release/` in source); third-party materials retain their own terms. Static MSVC runtime redistribution review remains open before maintainer publication. SHA-256 detects changed bytes; an unsigned manifest does not authenticate a publisher.
