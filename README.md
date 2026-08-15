# DMDClock for Windows and ESP32-S3

DMDClock recreates the classic DotClk clock and `.scn` animation display on a
Windows monitor or a supported Waveshare ESP32-S3 touchscreen.

**Current stable release: [v1.6.0](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest)**

![DMDClock scene playback](docs/screenshots/setup/scene-playback.png)

## Install on Windows

> **For:** Windows 10 or Windows 11 x64  
> **Recommended package:** `DMDClock-*-win-x64-setup.exe`  
> **Administrator rights:** Not required

![DMDClock running on Windows](docs/screenshots/install/windows-clock.png)

1. Open the [latest release](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest).
2. Expand **Assets** and download the file ending in `win-x64-setup.exe`.
3. Run the installer and keep the default per-user installation folder.
4. Start **DMDClock** from the Start Menu.
5. Right-click the display and choose **Download DotClk scenes…**.

The setup package includes the required .NET runtime. It can also install the
optional Windows screensaver and start-with-Windows shortcut. Installing a newer
setup EXE preserves settings, scene choices, and downloaded libraries.

For portable ZIPs, screensaver setup, keyboard controls, storage locations, and
troubleshooting, use the [complete Windows installation guide](docs/INSTALL-WINDOWS.md).

## Install on ESP32-S3

> **Supported:** Waveshare ESP32-S3-Touch-LCD-7, original 800×480 N16R8  
> **Supported:** Waveshare ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1, 640×172 N16R8  
> **Not compatible:** Waveshare 7B / 1024×600 or 3.49B V1

![DMDClock ESP32 web remote](docs/screenshots/install/esp32-web-remote.png)

### 1. Prepare the TF card

The card can be prepared before flashing. Card creation and formatting are
outside the DMDClock scripts: supply one healthy FAT32 volume and follow the
[Windows TF-card preparation guide](docs/PREPARE-ESP32-SD-CARD.md).

### 2. Download the flasher

Open PowerShell 7 in an empty folder and download the guarded flasher plus its
shared module:

```powershell
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/Flash-DmdClockEsp32.ps1' -OutFile 'Flash-DmdClockEsp32.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scripts/esp32/DmdClock.Provisioning.psm1' -OutFile 'DmdClock.Provisioning.psm1'
Unblock-File .\Flash-DmdClockEsp32.ps1, .\DmdClock.Provisioning.psm1
```

### 3. Verify and flash

1. Connect a data-capable USB cable to the board's documented programming/UART
   connector.
2. Run `.\Flash-DmdClockEsp32.ps1`.
3. Select the exact board, firmware release, flash mode, and COM port.
4. Confirm the physical model and PCB revision shown by the script.
5. Review the final summary and type `FLASH` only when every value is correct.

The application-update mode preserves NVS, Wi-Fi settings, and the TF card. The
script verifies the release manifest, target, package hash, firmware image hashes,
ESP32-S3 chip, and 16 MB flash before writing.

### 4. Configure the display

Connect the device to a 2.4 GHz Wi-Fi network and open the address shown on the
screen. The local web remote controls scenes, fonts, colours, brightness, clock
duration, schedules, and screen orientation. Automatic orientation is available
only on the 3.49B V2 through its QMI8658 sensor; both boards support fixed 0° and
180° orientation.

Use the [complete ESP32 installation guide](docs/INSTALL-ESP32.md) for first boot,
offline staging, recovery, security notes, and model-specific USB guidance.

## Scene libraries

Animations are not embedded in the application or firmware.

- **DMD-Large** is the preferred library with 2,416 scenes and includes the
  complete Original collection.
- **Original DotCLK-Orig** remains selectable separately with 2,324 scenes.
- User-provided compatible `.scn` files can also be selected.

Windows installs a selected library through **Download DotClk scenes…**. ESP32
libraries are prepared on Windows and copied to an already-FAT32 card with
`Prepare-DmdClockSdCard.ps1`; the firmware never formats or repartitions a card.

## Everyday controls

### Windows

- Right-click the display for clock, date, scene, colour, and screensaver settings.
- Press `T` for the clock, `D` for the date, `N` for the next scene, and `F11` for
  fullscreen.
- Open **Review and choose scenes…** to enable games and allow or block individual
  animations.

### ESP32-S3

- Use the touchscreen for the main playback actions.
- Use the local web remote for the full settings interface.
- Settings are saved in NVS and mirrored to the TF card when available.
- Wi-Fi credentials and the HTTP web interface stay on the local network; there
  is currently no web login or HTTPS, so use the device only on a trusted LAN.

## Screenshots

| Windows settings | Scene Reviewer |
| --- | --- |
| ![Windows settings menu](docs/screenshots/setup/settings-menu.png) | ![Scene Reviewer](docs/screenshots/setup/scene-reviewer.png) |
| C64 rainbow theme | Hot-core glow |
| ![C64 rainbow theme](docs/screenshots/colors/c64-rainbow.png) | ![Hot-core glow](docs/screenshots/colors/hot-core-classic.png) |

## Documentation

End users:

- [Install on Windows](docs/INSTALL-WINDOWS.md)
- [Install on ESP32-S3](docs/INSTALL-ESP32.md)
- [Prepare an ESP32 TF card](docs/PREPARE-ESP32-SD-CARD.md)
- [Settings reference](docs/SETTINGS.md)

Developers:

- [Development documentation](docs/development/README.md)
- [Active TODO](TODO.md)
- [Completed development history](docs/development/DEVELOPMENT-HISTORY.md)

## Data and privacy

Windows stores settings, indexes, review decisions, and logs under
`%LOCALAPPDATA%\DmdClock\`. ESP32 Wi-Fi credentials and settings remain on the
device and its TF card backup. Normal playback does not send scenes or preferences
to an AI service.

## Acknowledgements

DMDClock is inspired by sigmafx's original DotClk work. Source provenance and
technical references are recorded in
[the development reference](docs/development/reference/SOURCES.md), with bundled
font hashes in [the font reference](docs/development/reference/FONTS.md).

If DMDClock brings a little colour or nostalgia to your day, you can
[buy me a coffee](https://buymeacoffee.com/drwize).
