# Install DMDClock on the ESP32-S3 and SD card

Published DMDClock firmware supports two explicit N16R8 targets: the original
800×480 Waveshare `ESP32-S3-Touch-LCD-7` and the 640×172 Waveshare
`ESP32-S3-Touch-LCD-3.49B` **V2 / Rev1.1**. The 1024×600 7B and 3.49B V1 are
incompatible and must not be flashed with these packages.

The flashing menu filters release manifests by exact target. For 3.49B it also
requires an explicit V2 revision confirmation. Hash-verified official factory
recovery remains available for both 3.49B revisions, but the recovery image must
match the PCB revision and is separate from DMDClock firmware.

Recommended order: download the setup files, prepare the TF card, flash the
ESP32, insert the prepared card while powered off, then configure the web remote.
The card does not need a flashed or connected ESP32 and can be finished first.

## Select the correct programming connector

Not every USB or power connector provides a flashing UART. Check the official
interface diagram for the exact model before selecting a COM port:

| Model | Programming connection | Official links |
| --- | --- | --- |
| Waveshare ESP32-S3-Touch-LCD-7 | Use a data-capable cable in the **USB TO UART Type-C** port. | [Product homepage](https://www.waveshare.com/esp32-s3-touch-lcd-7.htm) · [Port diagram and documentation](https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7) |
| Waveshare ESP32-S3-Touch-LCD-3.49B | Use the Type-C connector identified for program flashing and log output. Confirm V2 / Rev1.1 before flashing DMDClock. | [Product homepage](https://www.waveshare.com/esp32-s3-touch-lcd-3.49.htm) · [Port diagram and documentation](https://docs.waveshare.com/ESP32-S3-Touch-LCD-3.49) |

If no port is detected, the script repeats the instructions and links for the
selected model. For the 7-inch board it also links the official
[WCH CH343 Windows driver](https://www.wch-ic.com/downloads/CH343SER_EXE.html).

The QEMU development profiles are not flash images. They emulate a classic
ESP32 with 4 MiB PSRAM because the virtual RGB device stalls on the ESP32-S3
machine. The supported N16R8 hardware instead has 8 MiB octal PSRAM. QEMU can
therefore expose memory-pressure problems, but it cannot prove ESP32-S3 timing,
RGB wiring, touch, or physical TF-card behavior.

## What you need

- the correct Waveshare board;
- a data-capable USB cable connected to the model-specific programming
  connector identified above;
- a FAT32 microSD/TF card with at least 256 MB free;
- a Windows 11 x64 PC running PowerShell 7 or newer as `pwsh`;
- this repository or downloaded copies of the two ESP32 entry scripts and their
  shared provisioning module.

The [latest release page][latest-release] is the canonical place for published
versions. `Flash-DmdClockEsp32.ps1` asks for the exact board first, then lists
only releases containing a compatible, hash-verified image for that selection.

## 1. Download the setup scripts

Create or open a clean folder in PowerShell. These commands download the latest
versions of both scripts directly from the `master` branch:

```powershell
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/Flash-DmdClockEsp32.ps1' -OutFile 'Flash-DmdClockEsp32.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/Prepare-DmdClockSdCard.ps1' -OutFile 'Prepare-DmdClockSdCard.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/DmdClock.Provisioning.psm1' -OutFile 'DmdClock.Provisioning.psm1'
```

`Flash-DmdClockEsp32.ps1` discovers compatible firmware releases, downloads and
verifies the selected image and flashing tool, checks the connected hardware,
and performs the flash. `Prepare-DmdClockSdCard.ps1` downloads and validates the
selected scene library and copies it to a FAT32 TF card. Neither script requires
a repository clone, Git, Python, .NET, or ESP-IDF.

If Windows marks the downloaded scripts as blocked, remove only their downloaded
file markers:

```powershell
Unblock-File -Path .\Flash-DmdClockEsp32.ps1, .\Prepare-DmdClockSdCard.ps1, .\DmdClock.Provisioning.psm1
```

Check the host without creating folders, downloading payloads, or enumerating
hardware:

```powershell
.\Flash-DmdClockEsp32.ps1 -CheckRequirements
.\Prepare-DmdClockSdCard.ps1 -CheckRequirements
```

### Stage once without attached hardware

These commands build one verified `DmdClockFiles` folder. No TF card or ESP32 is
required or enumerated. The first command stages the selected scene library; the
second adds firmware for both supported boards and official portable esptool.

```powershell
.\Prepare-DmdClockSdCard.ps1 -DownloadOnly `
  -Destination .\DmdClockFiles -Library DmdLarge
.\Flash-DmdClockEsp32.ps1 -DownloadOnly `
  -Destination .\DmdClockFiles
```

Preview either operation by adding `-WhatIf`; no destination is created. The
staging inventory is `DmdClockFiles\staging-manifest.json`, with per-run evidence
under `DmdClockFiles\Logs`.

For the card and flash entry points, `-DryRun` is equivalent to `-WhatIf`. It
creates no log, saved download, temporary extraction, cache, card write, or
flash, and it never opens a COM port. It may read GitHub release metadata and
enumerate disks or COM devices to display the exact plan.

Mutating staging runs write one non-secret evidence log below
`DmdClockFiles\Logs`. SD synchronization and flashing write theirs below
`%LOCALAPPDATA%\DmdClock\Logs\Provisioning`. Logs finish with an explicit
completed, cancelled, or failed outcome and redact credentials and URL queries.

Consume the verified bundle offline:

```powershell
.\Prepare-DmdClockSdCard.ps1 -DiskNumber 3 -Library DmdLarge `
  -Source .\DmdClockFiles -WhatIf
.\Flash-DmdClockEsp32.ps1 -Board Waveshare7 `
  -Source .\DmdClockFiles -DownloadOnly
```

Remove `-DownloadOnly` from the last command only when the correct board is
connected and you intend to proceed to guarded COM selection and flashing.

## 2. Prepare the SD card before flashing

The TF card is independent of the firmware installation. You can prepare it
completely **before connecting or flashing the ESP32**, then insert it after the
firmware installation is complete. This is often the easiest order because the
scene download and full SCN validation can finish while the board remains
disconnected.

Creating or formatting the card is outside the scope of DMDClock and its scripts.
Supply an already working FAT32 card. The single authoritative procedure for
checking the card and adding either scene library is the
[Windows TF-card preparation guide](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/blob/master/docs/PREPARE-ESP32-SD-CARD.md).
All formatting-tool guidance, including the official Rufus download location,
is maintained there.

Safely eject the prepared card and keep it aside. After flashing, power off the
ESP32, insert the card, and power it on. Firmware creates
`/dmd/config/settings.json` after mounting the card and mirrors later web-setting
changes to that file.

The prepared scene library uses the full display area on both supported boards:

| Waveshare 7 — 800×480 | Waveshare 3.49B V2 — 640×172 |
| --- | --- |
| ![Scene library controls on Waveshare 7](screenshots/install/esp32-scene-packs-waveshare7.png) | ![Scene library controls on Waveshare 3.49B V2](screenshots/install/esp32-scene-packs-landscape349.png) |

## 3. Connect and flash the ESP32-S3

1. Power off the board.
2. Connect a data-capable USB cable to the model-specific programming connector
   described above. Not every USB connector provides UART.
3. Open **Device Manager > Ports (COM & LPT)** and note which COM port appears
   when the board is connected.
4. From the folder containing the downloaded scripts, start the flasher:

```powershell
.\Flash-DmdClockEsp32.ps1
```

5. In the menu:

   1. Select the exact ESP32 display board.
   2. Select a stable or preview release containing an image for that board.
   3. Choose **Complete installation** for a new board, or **Application update**
      when updating an existing DMDClock installation.
   4. Select the COM port identified in Device Manager.
   5. Read the physical label on the board and enter the requested model
      confirmation.
   6. Review the final board, release, flash mode, and port summary.
   7. Type `FLASH` when ready. Uppercase or lowercase is accepted.

6. Keep USB power and the cable connected until the success message appears and
   the board restarts. The script stops before writing if the chip, flash size,
   board confirmation, package hash, or selected port does not match.

The script downloads a verified portable Espressif `esptool` when it is not
already cached under `%LOCALAPPDATA%\DmdClock\tools\esptool`. Python, ESP-IDF,
.NET, Git, and a globally installed flashing tool are not required.

Important hardware, preservation, and confirmation messages are colour-coded so
the supported `7`, unsupported `7B`, selected port/mode, and final write prompt
are easy to distinguish.

For example, a missing-port check stops before flashing and displays:

```text
[FAILED] No usable serial port was detected.

Check the physical USB connection and the selected model's official port
diagram. Open Device Manager > Ports (COM & LPT), then disconnect and reconnect
the board to identify the correct COM port.
```

Application updates preserve the bootloader, partition table, NVS/Wi-Fi settings,
and TF card. Complete installation writes the bootloader, partition table, and
application without issuing an erase command, so NVS and the TF card remain
untouched.

Download without flashing:

```powershell
.\Flash-DmdClockEsp32.ps1 -ReleaseTag v1.3.4 -DownloadOnly
```

### 3.49B V2 factory qualification

The 3.49B path restores official Waveshare factory firmware so the physical
LCD, touch, and SD hardware can be qualified before DMDClock support is enabled.
Preview every check without writing:

```powershell
.\Flash-DmdClockEsp32.ps1 -Board Waveshare349B -FactoryRecovery `
  -BoardRevision V2 -Port COM5 -ConfirmHardware 3.49B -WhatIf
```

Remove only `-WhatIf` to perform the recovery. The script still requires a final
case-insensitive `FLASH` confirmation and does not accept `-Force` in factory
recovery mode.

## 4. Open the web remote

If home Wi-Fi is not connected:

1. Join `DMDClock-xxxx` from a phone or computer.
2. Use Wi-Fi password `dmdclock`.
3. Open `http://192.168.4.1/`.

When home Wi-Fi has a DHCP lease, open the IP shown on the ESP32 startup screen.
The device name is also displayed, for example `DMDClock-59D9`.

To add or change the full scene library, power down the ESP32, remove the TF card,
and use the [Windows microSD card preparation guide](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/blob/master/docs/PREPARE-ESP32-SD-CARD.md).
Windows and macOS keep their normal in-app **Download scenes…** workflow for
desktop libraries. Full ESP32 library downloads are prepared on Windows to avoid
competing for the device's display, TLS, and SDMMC memory.

## Web settings guide

The remote is arranged from frequently used display controls at the top to
network, automation, and diagnostics farther down. Changes that say they apply
immediately are saved directly; use the section's **Save** button where one is
shown.

The table below summarizes which controls apply immediately (and save
automatically) and which wait for a **Save** button.

| Control | When it applies | Saved by |
| --- | --- | --- |
| Quick controls (next pinball/scene/theme, information, glow, NTP sync, clock, touch test) | Immediately on click | Automatically |
| Screen switch (`displayOn`) | Immediately on toggle | Automatically |
| Content mode and scene selection | Immediately | Automatically |
| Brightness and dot glow | Immediately as you slide | Automatically |
| Hot-core dots and centre colour | Immediately | Automatically |
| Colour theme, plasma palette, and motion loop | Immediately | Automatically |
| Clock font, 24-hour clock, show seconds, fixed clock duration | Immediately | Automatically |
| Scene information row and colour | Immediately | Automatically |
| Orientation (fixed 0°/180°, automatic) | Immediately | Automatically |
| Time zone and browser-time fallback | Immediately | Automatically |
| Scene cycling (automatic cycle, random order, per-cycle count, clock interval, playback log) | Immediately | Automatically |
| Weekly screen schedule | When you click **Save schedule** | **Save schedule** |
| Automatic weekly reboot | When you click **Save reboot schedule** | **Save reboot schedule** |
| Home Wi-Fi SSID/password and LAN-only web access | When you click **Save changes** | **Save changes** |
| MQTT discovery, broker, and credentials | When you click **Save changes** | **Save changes** |

The main **Save changes** button also re-sends a full snapshot of the display,
clock, theme, schedule, and cycling settings, so it is a safe fallback after
any direct control change.

### Quick controls and display

![DMDClock ESP32 web remote showing quick controls and display settings](screenshots/install/esp32-web-remote.png)

- **Quick controls** mirror the touchscreen actions: advance pinball or scene,
  change colour family/theme, toggle information and glow, synchronize time,
  show the clock, or start the touch test.
- **Screen** blanks or restores the DMD without shutting down the ESP32.
- **Content** selects the clock or an SD-card scene. The scene chooser includes
  pinball, scene, year, and manufacturer metadata when available.
- **Brightness** controls panel output. **Dot glow** controls the halo around
  each DMD dot, while **Hot-core dots** adds a brighter centre and optional
  centre colour.

### Colour themes

Choose Basic, Gradient, Raster, or Plasma, then select a theme within that
family. Theme changes apply immediately. Plasma additionally exposes palette
and motion-loop controls. These examples show the same shared DMD renderer with
two very different settings:

| C64 rainbow | Neon sunset |
| --- | --- |
| ![C64 rainbow DMD colour theme](screenshots/colors/c64-rainbow.png) | ![Neon sunset DMD colour theme](screenshots/colors/neon-sunset.png) |

### Clock, date, font, duration, and orientation

- Select 12- or 24-hour time, seconds visibility, scene-information overlay and
  colour, and one of the five embedded DotClk-compatible clock fonts.
- **Fixed clock duration** accepts a whole number from 1 to 600 seconds and
  displays the value in readable minutes and seconds.
- **Orientation** offers fixed 0° or 180° on both boards. The 3.49B V2 also
  offers **Automatic** as the default, using its QMI8658 sensor. Automatic is
  hidden on the Waveshare 7 because that board has no supported orientation
  sensor.

| Clock display | Date display |
| --- | --- |
| ![DMDClock time display](screenshots/time.png) | ![DMDClock date display](screenshots/date.png) |

### Schedules and scene cycling

- **Weekly screen schedule** paints the hours when the panel should be on or
  off. A touchscreen wake is temporary and does not rewrite the schedule.
- **Automatic weekly reboot** provides an optional maintenance restart at the
  selected weekday and time.
- **Windows-style scene cycle** controls automatic scene playback, the number
  of scenes per cycle, and the fixed 1–600 second clock interval between scene
  groups.

### Time, network, Home Assistant, and diagnostics

- **Time and network** selects the region/city timezone, synchronizes browser or
  NTP time, configures home Wi-Fi, and controls LAN-only web access.
- **Home Assistant and MQTT** is optional. It configures local MQTT discovery,
  broker address, credentials, and connection status; normal clock operation
  continues when MQTT is disabled or unavailable.
- The health section reports firmware, display, SD card, scene index, network,
  NTP, MQTT, memory, touch, and settings status for troubleshooting.

## Time and timezone

On first start, the browser supplies a usable fallback time. In **Time and
network**, choose a region and then a representative city that follows the same
UTC offset and daylight-saving changes as your location. The selector uses 90
current and predicted-future clock-rule groups split across eight regional data
files; `UTC` is always available. The selected time zone is applied and saved
immediately, without using the page's main Save button.

After home Wi-Fi connects, the ESP32 synchronizes automatically with
`pool.ntp.org` and `time.cloudflare.com`. It continues running from its local
timebase during temporary network or NTP outages and resynchronizes when the
connection returns.

The remote checks GitHub once per page load and displays a link when a newer build
exists. It never flashes firmware automatically.

## Passwords and network security

- The home Wi-Fi password is saved in device NVS. NVS encryption is not currently
  enabled.
- For backup and editability, `/dmd/config/settings.json` also contains the Wi-Fi
  password in plain text. Protect the SD card and any copy of this file.
- Leaving the password box blank in the web remote preserves the saved password.
- `dmdclock` is the WPA2 password for joining the recovery access point. It is
  not a web-page login.
- The web remote currently has no user login and uses HTTP, not HTTPS.
- **LAN-only web access** defaults to on. It accepts only clients on the ESP32's
  current station/AP subnet, loopback, or link-local addresses. It protects
  against accidental routing or port forwarding, but it does not protect against
  another device already on your LAN.

Keep LAN-only access enabled unless another trusted network firewall provides the
boundary. Never forward ESP32 port 80 from the internet.

Repository builds, ESP-IDF flashing, QEMU, and the optional one-time Wi-Fi
bootstrap are intentionally kept out of this end-user installation flow. See
the [ESP32 developer track](DEVELOPMENT.md#optional-esp32-wi-fi-bootstrap-and-local-flashing).

## Enclosures

Community designs change independently of this project. Verify the mounting holes
and that the model says `ESP32-S3-Touch-LCD-7`, not `7B`, before printing:

- [Waveshare ESP32-S3 7-inch wall-mount case on Printables][printables-case]
- [ESP32-S3-Touch-LCD-7 case on Thingiverse][thingiverse-case]
- [Official Waveshare dimensions and 3D drawing][waveshare-board]

For firmware internals, recovery, QEMU, and diagnostic details, see the
[firmware reference](development/esp32/FIRMWARE.md).

[latest-release]: https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest
[printables-case]: https://www.printables.com/model/1030369-waveshare-esp32-s3-7inch-capacitive-touch-display
[thingiverse-case]: https://www.thingiverse.com/thing:7273339
[waveshare-board]: https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7
