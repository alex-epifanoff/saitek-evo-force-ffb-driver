# Native Saitek force-feedback driver

This x64 user-mode DirectInput effect driver targets only USB `06A3:FFB5` with the
validated physical HID PID descriptor. It preserves the Microsoft HID input
binding used by X-Plane. It is an unsigned experimental alpha with physical and wider compatibility gates
still open; see [eligibility and limits](community-alpha.md).

Build and run both offline suites:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Driver.ps1
```

In a source checkout the binary is `out\driver\SaitekFfbDriver.dll`; the binary package carries `bin\SaitekFfbDriver.dll`. Its fixed CLSID is
`{1DB0C28F-6D99-416E-8D05-73DE59E6E170}`. The DLL exports only
`DllGetClassObject` and `DllCanUnloadNow`; it contains no registration entry point.
The separately reviewed installer owns reversible per-user registration.

`out\driver\build-manifest.json` records the binary hash, source and test hashes,
both offline test results, architecture, CLSID and exact supported registry
metadata. A failed build removes the previous manifest, and a skipped-test build
sets both test flags false. Source changes during a build invalidate its manifest.
Offline tests do not open hardware or establish physical force correctness.

The COM adapter stores effect parameters by value and assigns nonzero increasing
32-bit handles. It accepts native callback object IDs, including reserved bits,
and DirectInput's native polar direction representation. The physical transport
owns parameter-memory allocation and hardware slot mapping. Constant, spring,
damper, square, sine, triangle and both sawtooth waveforms are advertised. Triggered
effects, rotated two-axis single-condition forms, custom force, ramp, friction
and inertia are not advertised. Unsupported trigger and sample-period parameters
are ignored. Per-axis condition arrays map according to their actual X/Y object IDs.

Device discovery, cached gain, `NODOWNLOAD`, state queries and cleanup commands on
an unopened context do not claim or open output. The first actual download,
start or explicit actuator-enable command validates and opens the supplied HID
path with sharing. Output ownership is exclusive between instances of this
driver; ordinary HID input remains shared. The transport starts with actuators
disabled. An actual Start (including `DIEP_START`) enables them lazily unless the
application explicitly muted them with ACTUATORSOFF. Download alone never enables
output. Explicit OFF remains in force through STOPALL and RESET until a successful
ACTUATORSON or a new device session. Effects can start and their timers continue
while muted, without enabling the actuators. RESET removes effects and disables
actuators; a later Start follows the same default-versus-explicit-mute policy.

Lazy enabling supports the ordinary Acquire/Start pattern in Microsoft's
[FFConst sample](https://github.com/walbourn/directx-sdk-samples-reworked/blob/main/DirectInput/FFConst/ffconst.cpp).
It is an application compatibility policy. Muted playback follows Microsoft's
[effect-driver command contract](https://learn.microsoft.com/en-us/windows/win32/api/dinputd/nf-dinputd-idirectinputeffectdriver-sendforcefeedbackcommand);
RESET itself leaves output disabled as described by the
[application command contract](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee417918(v=vs.85)).

Downloading a stopped effect never starts it unless `DIEP_START` is supplied.
`DIEP_NODOWNLOAD` overrides `START`. Matching live amplitude, gain and direction
updates preserve effect storage and playback, including `NORESTART` updates.
Changes that require a restart return `DIERR_EFFECTPLAYING` with `NORESTART`;
otherwise the adapter stops, downloads and resumes that effect. Reset invalidates
all handles, and device I/O failure invalidates the affected context. A new begin
after end opens a fresh context without reusing old handles.

Effect gain and global gain are multiplied in the encoded amplitude parameters;
hardware device gain stays at its nominal maximum. They are not applied a second
time. State reports describe tracked effect playback, pause, actuator command and
memory use. Power supply and grip-switch state are not invented. Physical output
must still be checked separately.

The owner reports FFB working in X-Plane 12 on their setup, with the exact artifact and individual effects unconfirmed. Physical force direction, magnitude and useful flight feel require intentional acceptance of each release package. See [the flight guide](flying.md). No diagnostic probe or force-test action ships in this alpha.

Interface contracts follow Microsoft's
[DownloadEffect documentation](https://learn.microsoft.com/en-us/windows/win32/api/dinputd/nf-dinputd-idirectinputeffectdriver-downloadeffect)
and [effect direction documentation](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee417536(v=vs.85)).
The implementation is original code against the SDK and the observed device
descriptor; the Linux research implementation was not copied.
