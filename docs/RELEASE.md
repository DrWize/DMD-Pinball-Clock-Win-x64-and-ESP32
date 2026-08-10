# Download and install DMDClock

Use the [latest GitHub release][latest-release] for published, checksummed
packages. Scene animations are not bundled with the application or firmware;
both platforms provide a supported way to install them afterward.

## Windows 10 or 11 x64

1. Open the [latest release][latest-release] and expand **Assets**.
2. Download the file ending in `win-x64-setup.exe`.
3. Run the installer and keep the default per-user installation folder.
4. Start DMDClock, right-click the display, and choose
   **Download DotClk scenes…**.

The setup package includes the required .NET runtime and needs no administrator
rights. Installing a newer setup EXE over the existing version preserves
settings and downloaded scenes. If Windows displays a reputation warning,
verify the file against the release's `SHA256SUMS.txt`; never trust a copy from
another download site.

Prefer a ZIP instead?

- `win-x64-standalone.zip` includes the runtime and runs from any writable
  folder.
- `win-x64-portable.zip` keeps application files together for manual portable
  use.

See [Install DMDClock on Windows](INSTALL-WINDOWS.md) for screensaver setup,
upgrades, portable use, and troubleshooting.

## Waveshare ESP32-S3-Touch-LCD-7

> Supported hardware: only the original 800×480
> `ESP32-S3-Touch-LCD-7` with an N16R8 module. Do not flash the 1024×600 `7B`.

1. Download or clone this repository on Windows and open PowerShell in its root.
2. Connect the board through its **UART** USB-C port.
3. Run `.\scripts\esp32\Doctor.ps1` and note the exact COM port.
4. Run `.\scripts\esp32\Install-DmdClockEsp32.ps1`.
5. Select a compatible release, choose the COM port and flash mode, verify the
   physical board label, then type `FLASH` at the final confirmation.

The installer downloads and verifies the release manifest, target ID, firmware
ZIP, and image hashes before writing anything. An application update preserves
the bootloader, partition table, NVS/Wi-Fi settings, and TF card.

To install scenes, insert a FAT32 card in the PC and run the following command,
replacing `J:` with the verified removable drive:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 J:
```

The card preparation is idempotent: it does not format the card or delete
unrelated files. See [Install DMDClock on the ESP32-S3 and SD card](INSTALL-ESP32.md)
for first boot, Wi-Fi, recovery, security, and local-build instructions.

## Verify a download

Each release includes SHA-256 checksum files. From PowerShell:

```powershell
Get-FileHash .\DMDClock-* -Algorithm SHA256
```

Compare the complete hash with the matching entry downloaded from the same
GitHub release. A filename match alone is not verification.

## Developer QEMU profiles

QEMU images are local developer artifacts, not release firmware. Waveshare7 and
Landscape349 use independent build directories, writable SD images, web ports,
and monitor ports so both can run concurrently. Follow the
[firmware QEMU guide](../firmware/dmdclock-esp32/README.md#run-in-qemu) to create
the images and launch the profiles.

[latest-release]: https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest
