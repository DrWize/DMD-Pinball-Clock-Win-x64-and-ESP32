# DMDClock

DMDClock is a classic pinball dot-matrix-display clock. It can run on a Windows
or macOS computer, or directly on a supported Waveshare ESP32-S3 display. Add a
scene library to alternate animated pinball scenes with the clock.

**Latest release:** [GitHub Releases](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest)

## Choose your platform

| Platform | Status |
| --- | --- |
| Windows 11 | Supported |
| ESP32-S3-Touch-LCD-7 (800x480, N16R8) | Supported |
| ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1 (640x172, N16R8) | Supported |
| macOS Apple Silicon | Unsigned developer preview |

## Windows quick start

1. Download the Windows package from the latest release.
2. Run the setup EXE, or extract the standalone ZIP to a folder you can write to.
3. Start `DmdClock.App.exe`.
4. Open settings to select a scene folder, choose the clock/font/colours, and
   decide how scenes alternate with the clock.

The app works as a clock without any scenes. Settings and logs are stored in
`%LOCALAPPDATA%\DmdClock`, not beside the executable.

## ESP32-S3 quick start

You need a FAT32 microSD card (256 MB or larger), card reader, USB-C data cable,
a supported board, Windows 11, and PowerShell 7.

1. Download the current `RUNME-Install-DmdClockEsp32.ps1` from the latest
   release and run it from a clean folder:

   ```powershell
   Unblock-File .\RUNME-Install-DmdClockEsp32.ps1
   .\RUNME-Install-DmdClockEsp32.ps1 -CheckRequirements
   .\RUNME-Install-DmdClockEsp32.ps1 -Wizard
   ```

2. Let the wizard prepare the card, insert it while the board is powered off,
   then select the board and its verified UART COM port for flashing.
3. Power on the board, join its Wi-Fi access point, open the shown local web
   address, and set time zone, network, display preferences, and scene library.

Use `-WhatIf` to preview an operation. `-DownloadOnly` stages the library,
firmware, and flasher without a card or board. Never select a disk number until
you have confirmed it is the intended removable card.

## macOS quick start

> **Developer preview:** the Apple Silicon app is unsigned and not notarized.
> Gatekeeper will require an explicit first-launch confirmation.

1. Download the macOS package from the latest release.
2. Move `DMDClock.app` to `Applications`.
3. Control-click the app, choose **Open**, then confirm **Open** in Gatekeeper.

Settings are stored in `~/Library/Application Support/DmdClock`. Do not treat
this preview as a signed public macOS release.

## Scene libraries

| Library | Scenes | Notes |
| --- | ---: | --- |
| DMD-Large | 2,416 | Recommended extended library |
| DotCLK-Orig | 2,324 | Original DotClk collection |

`scene-metadata.json` is supplied with the application and prepared ESP32 card.
Unknown or custom `.scn` files still play; they use their filename when no
verified metadata exists.

## Help and project status

- [Developer guide](docs/development/README.md) — builds, advanced recovery,
  hardware, formats, and release maintenance.
- [Project status](STATUS.md) — verified completed work, open blockers, and
  prioritized next steps.
- [Historical documentation](docs/legacy/) — preserved guides, release notes,
  design notes, and earlier plans.

Original DotClk resources and related scene formats are credited to
[sigmafx/DotClk-Resources](https://github.com/sigmafx/DotClk-Resources).
