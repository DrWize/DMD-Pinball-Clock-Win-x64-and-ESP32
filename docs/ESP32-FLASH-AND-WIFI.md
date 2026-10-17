# Flash an ESP32 clock and configure Wi-Fi from PowerShell

Use Windows PowerShell 7 (`pwsh`), a USB data cable, and the scripts in
`scripts/esp32`. Supported boards are Waveshare7 (800x480) and Waveshare349B
V2 / Rev1.1 (640x172). Keep the existing scene microSD cards in place.

## Availability

Serial Wi-Fi setup is included in v1.9.0 for both supported boards. UART/CH343
and native USB reader tests pass. Both physical boards completed COM Wi-Fi
setup and natural NTP synchronization with the preceding developer firmware;
connections also survived subsequent application-flash restarts. Dedicated cold
power-cycle and clean downloaded-package checks remain in the [TODO](../TODO.md).

The published v1.8.0 firmware does **not** support these serial commands.
Install v1.9.0 firmware first, then use the Wi-Fi-only menu or optional post-flash
prompt. Wi-Fi-only setup needs no compiler or ChatGPT.

## Identify the clock

From the repository root:

```powershell
Get-PnpDevice -PresentOnly -Class Ports | Format-Table Status, FriendlyName, InstanceId
```

The recorded workstation mapping is COM4 = Waveshare7 / CH343 USB serial
`5B3E087595`, and COM3 = Waveshare349B / native USB serial
`28:84:85:92:B1:34`. Verify these identities each time; COM numbers can change.
Close other serial monitors before flashing or Wi-Fi setup.

Flashing restarts the clock. Connecting home Wi-Fi automatically starts NTP.
If investigating drift, capture the existing API time and sync history against
an external reference **before** either operation. Do not use an unsynchronized
PC clock as the sole reference.

## Developer build and first installation

These commands use the workstation's existing ESP-IDF Environment Manager
setup through the repository wrapper. They build images without embedded
Wi-Fi credentials and perform application-only flashing, preserving NVS and
the microSD card. Verify the port mapping above before running the flash line.

For the 7-inch clock:

```powershell
.\scripts\esp32\dev\Build-DmdClock.ps1 -Board Waveshare7 -Version 1.9.0-serial-wifi.3 -BuildDir build-serial-wifi-7
.\scripts\esp32\dev\Invoke-Idf.ps1 -ProjectPath .\firmware\dmdclock-esp32 -IdfArguments @('-B','build-serial-wifi-7','-p','COM4','app-flash')
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -Board Waveshare7 -Port COM4 -WifiOnly
```

For the 3.49B clock:

```powershell
.\scripts\esp32\dev\Build-DmdClock.ps1 -Board Waveshare349B -Version 1.9.0-serial-wifi.3 -BuildDir build-serial-wifi-349b
.\scripts\esp32\dev\Invoke-Idf.ps1 -ProjectPath .\firmware\dmdclock-esp32 -IdfArguments @('-B','build-serial-wifi-349b','-p','COM3','app-flash')
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -Board Waveshare349B -Port COM3 -WifiOnly
```

The build helper reports `Bootstrap Wi-Fi injection: OFF`. If it reports `ON`,
remove the local bootstrap header using the documented bootstrap cleanup before
making a shareable build. Never distribute an image containing your credentials.

## Change Wi-Fi without flashing

Run either command below. The tool checks protocol support and board identity
before prompting for the SSID and a hidden password. Use a 2.4 GHz network.
An empty password explicitly selects an open network.

```powershell
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -Board Waveshare7 -Port COM4 -WifiOnly
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -Board Waveshare349B -Port COM3 -WifiOnly
```

`RUNME-Install-DmdClockEsp32.ps1` also accepts `-WifiOnly -Board ... -Port ...`.
Its interactive menu has a **Configure Wi-Fi only** option. Add `-WhatIf` to
preview this operation without opening a COM port or requesting credentials.

## Release updates with Wi-Fi setup

With v1.9.0 or later, use:

```powershell
.\scripts\esp32\RUNME-Install-DmdClockEsp32.ps1 -Update -SkipCard -Board Waveshare7 -FlashMode Application -Port COM4 -ConfigureWifi
.\scripts\esp32\RUNME-Install-DmdClockEsp32.ps1 -Update -SkipCard -Board Waveshare349B -BoardRevision V2 -ConfirmHardware 3.49B -FlashMode Application -Port COM3 -ConfigureWifi
```

The lower-level `Flash-DmdClockEsp32.ps1` also accepts `-ConfigureWifi`.
Omit it to preserve saved Wi-Fi; interactive flashing offers an optional Wi-Fi
prompt after success. `-Force` skips that optional prompt but still honors an
explicit `-ConfigureWifi`. Neither flag supplies or prints the password.

For repeatable runs, use the verified release tag rather than changing versions
midway through a two-device update. `-DownloadOnly` stages the normal firmware
and tool payloads; a later `Flash-DmdClockEsp32.ps1 -Source <staging-folder>`
run can flash them offline. Wi-Fi provisioning itself needs no PC internet.
Do not combine Wi-Fi setup flags with download-only or factory recovery.

## Native USB timeout in the first candidate

The original `1.9.0-serial-wifi` candidate opened the primary USB VFS path even
when USB was configured as a secondary console. That left native USB input
unread and could produce a Windows semaphore/write timeout on COM3.
`1.9.0-serial-wifi.1` corrected the registered secondary path. A second issue
remained: ESP-IDF 5.5.2 VFS reports available USB input only from the installed
driver RX ring. `1.9.0-serial-wifi.2` installs a buffered USB driver and connects
the VFS to it. Live USB still failed. `1.9.0-serial-wifi.3` uses buffered UART
and USB driver reads with explicit zero timeouts, avoiding shared console VFS
read flags. This version passed live COM3 identity/status checks. The production
C test checks zero-timeout input while UART is idle, driver installation, protocol
handling, and initialization failures.

If you installed an earlier candidate, close serial monitors and application-
flash the corrected candidate using the command above, then rerun `-WifiOnly`.
The PowerShell tool now closes the failed handle and reports the transport error;
it does not reset or reflash automatically. If the port remains unusable even for
flashing, unplug/reconnect the USB cable before retrying (this may restart the
clock). No Wi-Fi credentials are sent until the initial identity reply succeeds.

## Verify and recover

Success means the clock reports association to the requested SSID and an IP,
not merely that it accepted the credentials. Open the printed `/api/state` URL
or read it with `Invoke-RestMethod` and confirm firmware, station IP, timezone,
`ntpSynced`, and a recent `ntpLastSync`. Check time against an external reference.
After a normal restart, verify the connection returns and settings persist.
Also check the physical display and touch controls.

If the password/network is wrong, rerun Wi-Fi-only setup. Credentials can be
saved even when association fails. A save error may mean NVS succeeded but the
SD settings mirror failed; resolve the card error and retry. Do not factory reset
just to change Wi-Fi. If firmware is unsupported, install compatible firmware
or connect to its `DMDClock-...` AP (password `dmdclock`) and use the web setup
at `http://192.168.4.1/`.

The scripts keep passwords out of their output and provisioning logs. The
device still stores credentials in its existing NVS and SD settings mirror;
protect the card and settings backups.

Read-only serial diagnostics are also available through `/api/state`:
`serialReaderRunning`, `serialPollCount`, `serialUartRxBytes`, `serialUsbRxBytes`,
and `serialRequests`. They expose counters only, with no credential contents.
