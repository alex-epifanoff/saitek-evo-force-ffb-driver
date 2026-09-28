# First intentional flight in X-Plane 12

First read [eligibility](community-alpha.md) and complete the explicit [installation](native-install.md). Obtain the supported official Bridge separately. The setup menu and support collector never start forces.

1. Fully exit any Bridge instance, including its tray icon. Launch it using the optional **Saitek FFB-Bridge** shortcut created through `Start.cmd`; for a one-off launch, run `tools/Start-SaitekFfbBridge.ps1` in native Windows PowerShell. The launcher validates its exact installed identities and never Arms the device itself.
2. Load the desired X-Plane 12 aircraft and keep the simulator paused initially. In joystick settings, check pitch, roll, rudder and throttle movement and direction. Normal input should remain available; stop if it does not.
3. In Bridge, open **Hardware → Device**, enable **Allow unlisted devices (experimental)** if needed, and use **Change device…** to select the `06A3:FFB5` FFB joystick.
4. Open **Hardware → Effects**. Use **Effect rendering: Software** and **Windows device backend: DirectInput/PID**. A greyed-out **Raw HID/PID** option is normal for this path. Review the intended aircraft/profile and use conservative force strengths. The package changes none of these Bridge settings.
5. Wait for the X-Plane connection and intended profile. With your hand positioned to assess the stick, intentionally click **Arm**. Check resistance and direction before proceeding; Disarm immediately if the behavior is wrong. Neither installation nor the launcher Arms automatically.
6. Set throttle and parking brake deliberately, then unpause when ready. Pause again if needed. Aircraft changes can disarm Bridge; review the new profile before rearming.

To stop forces, click **Disarm**. Pausing X-Plane is a separate simulator action and is not a substitute for Disarm. If the application is unresponsive and output continues, disconnect the joystick's motor power if safe to do so. Fully exit Bridge at the end; closing its main window can leave it running in the tray. Use the launcher for each fresh session so its process-only workaround applies.

The owner reports that FFB works in X-Plane 12 on their setup; the precise artifact and effects behind that report are unconfirmed. The earlier session produced noticeable pitch/roll centering during flight at **70% / 70%**. Vibration was adjusted to **40%** after weak effects were reported; improvement from that adjustment was not confirmed. These are observations, **not package defaults or recommended initial strengths**. This release package and individual periodic effects still require physical acceptance.

There is no automatic reconnect or replay. After a disconnect, Disarm, fully exit Bridge, resolve the connection and start a fresh session before intentionally Arming again. Reconnect and second-PC acceptance remain open. See [launcher restrictions](bridge-launcher.md) and the package's `RELEASE-STATUS.md` (`release/RELEASE-STATUS.md` in source).
