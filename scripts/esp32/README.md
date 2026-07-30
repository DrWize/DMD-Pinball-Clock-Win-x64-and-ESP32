# ESP32-S3 local tools

Repository:
[DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32).

These scripts use the pinned, workspace-local ESP-IDF 5.5.2 installation under
`E:\ai\.tools`. They do not require ESP-IDF, Python, CMake, Ninja, or the Xtensa
compiler on the global `PATH`.

```powershell
# Verify the local toolchain and list connected serial devices.
.\scripts\esp32\Doctor.ps1

# Rebuild the cached official Waveshare LVGL example.
.\scripts\esp32\Build-WaveshareExample.ps1 -Example LVGL

# Build another cached hardware test.
.\scripts\esp32\Build-WaveshareExample.ps1 -Example SD

# Validate and preview preparation of an already-formatted FAT32 card.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F -WhatIf

# Download, validate, and idempotently install the complete DotClk scene set.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F

# Run any idf.py operation against an explicit project.
.\scripts\esp32\Invoke-Idf.ps1 -ProjectPath <path> build

# Build the production DMDClock firmware. This never flashes a device.
.\scripts\esp32\Build-DmdClock.ps1

# Generate a one-time, ignored first-flash Wi-Fi header and build with it.
# The password is entered through a masked SecureString prompt.
.\scripts\esp32\Set-DmdClockBootstrapWifi.ps1 -WifiSsid 'My Wi-Fi' -Build

# After the first connection, remove the header and rebuild. A normal flash
# preserves the credentials that firmware copied into NVS.
.\scripts\esp32\Clear-DmdClockBootstrapWifi.ps1 -Build

# Build and run the ESP32-S3 QEMU profile with its virtual RGB display.
.\scripts\esp32\Build-DmdClockQemu.ps1
.\scripts\esp32\Run-DmdClockQemu.ps1

# Flash the exact connected port after confirming the 800x480 N16R8 board.
.\scripts\esp32\Flash-DmdClock.ps1 -Port COM5 -Monitor
```

After the clock boots, it creates `/dmd/config/settings.json` and mirrors every
web setting change to it. Back up that file before replacing or reformatting a
card. It includes the Wi-Fi password in plain text.

Production firmware indexes every flat `.scn` file in `/dmd/scenes` (up to
4,096 files); the prepared DotClk card currently contains 2,324. Optional
playback logging is controlled from the web remote and writes the bounded
`/dmd/logs/playback.log` plus one rotated previous file.

The vendor package is ignored by Git and stored at
`external\waveshare-esp32-s3-touch-lcd-7`. Its downloaded archive has SHA-256
`5351D443EAA605CAB1EB80D050D867C18E1CE2B33C9CBC78AAE1B7BCA040B038`.

QEMU needs the 64-bit MSYS2 `libiconv` runtime at
`C:\msys64\mingw64\bin\libiconv-2.dll`. The runner adds that directory only to
its child process environment; it does not copy DLLs into Windows.

Building does not touch connected hardware. The Windows USB-driver installer
requires an Administrator terminal; run it only if Windows does not recognize
the board automatically.

`dmd_bootstrap_wifi.h` is deliberately ignored by Git. Never attach it to an
issue, commit it, place it in a release archive, or use a real password in a
QEMU build. Rebuild and reflash without it after the device connects; do not
erase NVS during that cleanup flash.
