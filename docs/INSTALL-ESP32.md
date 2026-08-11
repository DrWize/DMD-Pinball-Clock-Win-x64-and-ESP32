# Install DMDClock on the ESP32-S3 and SD card

This guide and every published DMDClock ESP32 image support only the original
Waveshare `ESP32-S3-Touch-LCD-7`, `ESP32-S3-WROOM-1-N16R8`, with an 800×480
display. The 1024×600 `ESP32-S3-Touch-LCD-7B` is not supported and must not be
flashed with these packages.

The firmware also defines a second development board target, a 3.49-inch
`640×172` landscape panel (`DMD_BOARD_3_49_LANDSCAPE`), selectable through the
`DMD_BOARD` Kconfig choice. It is validated in QEMU only so far and is not part
of any published release image; it is not a supported flashing target until
emulation-first validation completes and physical bring-up passes.

The flashing menu reserves **Waveshare ESP32-S3-Touch-LCD-3.49B** so a matching
image can be published later without changing the user workflow. Selecting it
currently reports that no compatible release exists. Do not substitute the
7-inch image.

## Select the correct programming connector

Not every USB or power connector provides a flashing UART. Check the official
interface diagram for the exact model before selecting a COM port:

| Model | Programming connection | Official links |
| --- | --- | --- |
| Waveshare ESP32-S3-Touch-LCD-7 | Use a data-capable cable in the **USB TO UART Type-C** port. | [Product homepage](https://www.waveshare.com/esp32-s3-touch-lcd-7.htm) · [Port diagram and documentation](https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7) |
| Waveshare ESP32-S3-Touch-LCD-3.49B | Use the Type-C connector identified for program flashing and log output. Confirm the PCB revision before a future physical test. | [Product homepage](https://www.waveshare.com/esp32-s3-touch-lcd-3.49.htm) · [Port diagram and documentation](https://docs.waveshare.com/ESP32-S3-Touch-LCD-3.49) |

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
- a 64-bit Windows PC with Windows PowerShell 5.1 or newer;
- this repository or a downloaded copy of the two ESP32 PowerShell scripts.

The [latest release page][latest-release] is the canonical place for published
versions. `Flash-DmdClockEsp32.ps1` asks for the exact board first, then lists
only releases containing a compatible, hash-verified image for that selection.

## 1. Download the two setup scripts

Create or open a clean folder in PowerShell. These commands download the latest
versions of both scripts directly from the `master` branch:

```powershell
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/Flash-DmdClockEsp32.ps1' -OutFile 'Flash-DmdClockEsp32.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/Prepare-DmdClockSdCard.ps1' -OutFile 'Prepare-DmdClockSdCard.ps1'
```

`Flash-DmdClockEsp32.ps1` discovers compatible firmware releases, downloads and
verifies the selected image and flashing tool, checks the connected hardware,
and performs the flash. `Prepare-DmdClockSdCard.ps1` downloads and validates the
selected scene library and copies it to a FAT32 TF card. Neither script requires
a repository clone, Git, Python, .NET, or ESP-IDF.

If Windows marks the downloaded scripts as blocked, remove only their downloaded
file markers:

```powershell
Unblock-File -Path .\Flash-DmdClockEsp32.ps1, .\Prepare-DmdClockSdCard.ps1
```

## 2. Connect and flash the ESP32-S3

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

![DMDClock ESP32 web remote after installation](screenshots/install/esp32-web-remote.png)

## 3. Prepare the SD card

Follow the complete [Windows TF-card preparation article](PREPARE-ESP32-SD-CARD.md)
to identify and, when necessary, format the correct card safely. The preparation
script does not format media.

Insert the FAT32 card into the PC and confirm its drive letter, volume label, and
capacity in File Explorer. The following examples use `J:`.

Prepare preferred DMD-Large:

```powershell
.\Prepare-DmdClockSdCard.ps1 `
  -DriveLetter J `
  -Library DmdLarge
```

Prepare Original DotCLK-Orig instead:

```powershell
.\Prepare-DmdClockSdCard.ps1 `
  -DriveLetter J `
  -Library Original
```

The script verifies the target, downloads or reuses the selected version, checks
the published size and SHA-256, validates every SCN, and creates:

```text
J:\dmd\scenes\
J:\dmd\config\scene-library-manifest.json
```

It is idempotent: rerunning it reports matching files as unchanged and writes
nothing. Switching libraries removes only files recorded as managed by the
previous run. It never formats the card or deletes unrelated/custom SCNs. Eject
the card safely, insert it into the unpowered ESP32, and power the board again.
Firmware creates
`J:\dmd\config\settings.json` after it mounts the card and mirrors every later web
setting change to that file.

## 4. Open the web remote

If home Wi-Fi is not connected:

1. Join `DMDClock-xxxx` from a phone or computer.
2. Use Wi-Fi password `dmdclock`.
3. Open `http://192.168.4.1/`.

When home Wi-Fi has a DHCP lease, open the IP shown on the ESP32 startup screen.
The device name is also displayed, for example `DMDClock-59D9`.

![DMDClock ESP32 web remote](screenshots/install/esp32-web-remote.png)

To add or change the full scene library, power down the ESP32, remove the TF card,
and use the [Windows TF-card preparation article](PREPARE-ESP32-SD-CARD.md).
Windows and macOS keep their normal in-app **Download scenes…** workflow for
desktop libraries. Full ESP32 library downloads are prepared on Windows to avoid
competing for the device's display, TLS, and SDMMC memory.

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

## Optional developer Wi-Fi bootstrap and local build

This section requires a repository clone and the development prerequisites. It
is not needed when using the release flasher above.

From the repository root, create the one-time local bootstrap header. The password
prompt is masked and the generated header is ignored by Git:

```powershell
.\scripts\esp32\Set-DmdClockBootstrapWifi.ps1 `
  -WifiSsid 'Your 2.4 GHz Wi-Fi name' `
  -Build
```

The ESP32-S3 supports 2.4 GHz Wi-Fi, not a 5 GHz-only network.

Developers can flash a current local build through the pinned ESP-IDF wrapper:

```powershell
.\scripts\esp32\Doctor.ps1
.\scripts\esp32\Invoke-Idf.ps1 `
  -ProjectPath .\firmware\dmdclock-esp32 `
  -p COM5 -B build-hw-esp32 flash monitor
```

Replace `COM5` with the exact connected port reported by the doctor. The flash
script refuses to guess a port. On first boot, the device copies the bootstrap
Wi-Fi credentials into NVS and starts a recovery network named
`DMDClock-xxxx`.

After the home-network connection works, remove the credentials from subsequent
firmware images while preserving NVS:

```powershell
.\scripts\esp32\Clear-DmdClockBootstrapWifi.ps1 -Build
.\scripts\esp32\Invoke-Idf.ps1 `
  -ProjectPath .\firmware\dmdclock-esp32 `
  -p COM5 -B build-hw-esp32 app-flash
```

Do not erase the device during this cleanup flash.

## Enclosures

Community designs change independently of this project. Verify the mounting holes
and that the model says `ESP32-S3-Touch-LCD-7`, not `7B`, before printing:

- [Waveshare ESP32-S3 7-inch wall-mount case on Printables][printables-case]
- [ESP32-S3-Touch-LCD-7 case on Thingiverse][thingiverse-case]
- [Official Waveshare dimensions and 3D drawing][waveshare-board]

For firmware internals, recovery, QEMU, and diagnostic details, see the
[firmware reference](../firmware/dmdclock-esp32/README.md).

[latest-release]: https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest
[printables-case]: https://www.printables.com/model/1030369-waveshare-esp32-s3-7inch-capacitive-touch-display
[thingiverse-case]: https://www.thingiverse.com/thing:7273339
[waveshare-board]: https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7
