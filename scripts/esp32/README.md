# ESP32-S3 local tools

Repository:
[DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32).

These scripts use the pinned, workspace-local ESP-IDF 5.5.2 installation under
`E:\ai\.tools`. They do not require ESP-IDF, Python, CMake, Ninja, or the Xtensa
compiler on the global `PATH`. Run the scripts from PowerShell 7 (`pwsh`), not
Windows PowerShell 5.1.

```powershell
# Verify the local toolchain and list connected serial devices.
.\scripts\esp32\Doctor.ps1

# Rebuild the cached official Waveshare LVGL example.
.\scripts\esp32\Build-WaveshareExample.ps1 -Example LVGL

# Build another cached hardware test.
.\scripts\esp32\Build-WaveshareExample.ps1 -Example SD

# Validate and preview preparation of an already-formatted FAT32 card.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F -Library Original -WhatIf

# Download, validate, and idempotently install Original DotCLK-Orig.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F -Library Original

# Or prepare the larger DMD-Large library.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F -Library DmdLarge

# Run any idf.py operation against an explicit project.
.\scripts\esp32\Invoke-Idf.ps1 -ProjectPath <path> build

# Build the production DMDClock firmware. This never flashes a device.
.\scripts\esp32\Build-DmdClock.ps1

# Download a published ESP32 release, verify it, and optionally flash it.
# This is the single supported flashing entry point.
.\scripts\esp32\Install-DmdClockEsp32.ps1

# Flash the current local build instead of downloading a release.
.\scripts\esp32\Install-DmdClockEsp32.ps1 -LocalBuild -Port COM5 -Monitor

# Package a credential-free local build for a GitHub release.
.\scripts\esp32\Package-DmdClockEsp32.ps1

# Include the verified ESP32 artifacts when previewing the combined release.
.\scripts\Publish-GitHubRelease.ps1 -Tag v1.3.2 -IncludeEsp32 -WhatIf

# Generate a one-time, ignored first-flash Wi-Fi header and build with it.
# The password is entered through a masked SecureString prompt.
.\scripts\esp32\Set-DmdClockBootstrapWifi.ps1 -WifiSsid 'My Wi-Fi' -Build

# After the first connection, remove the header and rebuild. A normal flash
# preserves the credentials that firmware copied into NVS.
.\scripts\esp32\Clear-DmdClockBootstrapWifi.ps1 -Build

# Build and run the ESP32-S3 QEMU profile with its virtual RGB display.
.\scripts\esp32\Build-DmdClockQemu.ps1
.\scripts\esp32\Run-DmdClockQemu.ps1

# Run both models concurrently from separate terminals. Each uses its own build
# directory, SD image, web port, and QEMU monitor port.
.\scripts\esp32\New-DmdClockQemuSdImage.ps1 -ScenesFolder .\scenes `
  -OutputPath .\firmware\dmdclock-esp32\dmdclock-qemu-sd-waveshare7.img
.\scripts\esp32\New-DmdClockQemuSdImage.ps1 -ScenesFolder .\scenes `
  -OutputPath .\firmware\dmdclock-esp32\dmdclock-qemu-sd-landscape349.img
.\scripts\esp32\Run-DmdClockQemuModel.ps1 -Model Waveshare7
.\scripts\esp32\Run-DmdClockQemuModel.ps1 -Model Landscape349 -SkipBuild

```

`Install-DmdClockEsp32.ps1` is the only supported flashing command. Its menu can
download a published release, use an offline release package, or use the current
local build. It verifies target metadata and hashes, offers application-only or
complete flashing, requires an explicit COM port, checks for an ESP32-S3 with
16 MB flash, and never erases NVS.

The only supported display board is the original Waveshare
`ESP32-S3-Touch-LCD-7`, 800×480, with an `ESP32-S3-WROOM-1-N16R8` module. The
later `ESP32-S3-Touch-LCD-7B`, 1024×600, is not supported. Chip detection cannot
distinguish their LCD wiring, so the installer also requires confirmation from
the physical board label.

After the clock boots, it creates `/dmd/config/settings.json` and mirrors every
web setting change to it. Back up that file before replacing or reformatting a
card. It includes the Wi-Fi password in plain text.

Production firmware indexes every flat `.scn` file in `/dmd/scenes` (up to
4,096 files); the prepared DotClk card currently contains 2,324. Optional
playback logging is controlled from the web remote and writes the bounded
`/dmd/logs/playback.log` plus one rotated previous file.

`Prepare-DmdClockSdCard.ps1` defaults to preferred **DMD-Large** (2,416 scenes);
**Original DotCLK-Orig** (2,324 scenes) remains selectable. Preparation validates
the shared catalog, byte size, SHA-256, and every SCN. A managed scene list
prevents files from the previously selected library from being treated as custom
when switching libraries.

`Measure-ScenePackDelivery.ps1` records the real ZIP phases from a running QEMU
profile or compares the revision-pinned ZIP with sequential downloads of every
source scene. Logs and machine-readable summaries are written below
`output\benchmarks\scene-pack-delivery`. See
[`docs/SCENE-PACK-DELIVERY-BENCHMARK.md`](../../docs/SCENE-PACK-DELIVERY-BENCHMARK.md)
for the measured result and reproduction commands.

The vendor package is ignored by Git and stored at
`external\waveshare-esp32-s3-touch-lcd-7`. Its downloaded archive has SHA-256
`5351D443EAA605CAB1EB80D050D867C18E1CE2B33C9CBC78AAE1B7BCA040B038`.

QEMU needs the 64-bit MSYS2 `libiconv` runtime at
`C:\msys64\mingw64\bin\libiconv-2.dll`. The runner adds that directory only to
its child process environment; it does not copy DLLs into Windows.

`Run-DmdClockQemuModel.ps1` launches two board profiles: `Waveshare7`
(800×480, DMD 6×) and `Landscape349` (640×172, DMD 5×). The smaller
`Landscape349` profile is also the geometry-validation target; on it the
information text renders at the very bottom of the panel (`INFO_TEXT_Y =
LCD_HEIGHT - 19`) with a translucent black backing strip, below the touch
buttons and over the DMD. `Waveshare7` uses
`dmdclock-qemu-sd-waveshare7.img`, web port 8080, and monitor port 4444.
`Landscape349` uses `dmdclock-qemu-sd-landscape349.img`, web port 8081, and
monitor port 4445. These separate resources allow both profiles to run at the
same time. Override them with `-SdImage`, `-WebPort`, or `-MonitorPort`. If the
model's default image does not exist and no explicit image is supplied, QEMU
boots with the deterministic 11-scene embedded fallback.

`New-DmdClockQemuSdImage.ps1` creates a power-of-two 512 MiB FAT32 superfloppy
with its boot sector at LBA 0, which is the layout accepted by QEMU's ESP32
SD/MMC device. Larger images are selected automatically when necessary. The
generated images are writable and ignored by Git; never publish one containing
scenes unless their distribution rights are confirmed.

Both QEMU models emulate a classic ESP32 with 4 MiB quad PSRAM at 40 MHz and
16 MiB flash. The physical Waveshare N16R8 is an ESP32-S3 with 8 MiB octal
PSRAM at 80 MHz and 16 MiB flash. The lower QEMU PSRAM ceiling is useful for
finding oversized allocations, but QEMU is not cycle-accurate hardware testing.

Building does not touch connected hardware. The Windows USB-driver installer
requires an Administrator terminal; run it only if Windows does not recognize
the board automatically.

`dmd_bootstrap_wifi.h` is deliberately ignored by Git. Never attach it to an
issue, commit it, place it in a release archive, or use a real password in a
QEMU build. Rebuild and reflash without it after the device connects; do not
erase NVS during that cleanup flash.
