# ESP32-S3 local tools

Repository:
[DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32).

The build, QEMU, doctor, and developer scripts use the pinned, workspace-local
ESP-IDF 5.5.2 installation under `E:\ai\.tools`; they do not require those tools
on the global `PATH`. The user-facing `Flash-DmdClockEsp32.ps1` and
`Prepare-DmdClockSdCard.ps1` run on Windows 11 x64 with PowerShell 7 or newer
(`pwsh`) and do not
require Python, ESP-IDF, .NET, Git, CMake, Ninja, or the Xtensa compiler.

```powershell
# Verify the local toolchain and list connected serial devices.
.\scripts\esp32\dev\Doctor.ps1

# Rebuild the cached official Waveshare LVGL example.
.\scripts\esp32\dev\Build-WaveshareExample.ps1 -Example LVGL

# Build another cached hardware test.
.\scripts\esp32\dev\Build-WaveshareExample.ps1 -Example SD

# Read-only Windows 11 x64 / pwsh 7 requirements checks.
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -CheckRequirements
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -CheckRequirements

# Stage the selected microSD library, both firmware targets, and esptool with no hardware.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DownloadOnly `
  -Destination .\DmdClockFiles -Library DmdLarge
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -DownloadOnly `
  -Destination .\DmdClockFiles

# Verify offline payloads without a card or ESP32.
.\scripts\esp32\Flash-DmdClockEsp32.ps1 -Board Waveshare349B `
  -Source .\DmdClockFiles -DownloadOnly

# Card creation/formatting and current scene-library preparation:
# https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/blob/master/docs/PREPARE-ESP32-SD-CARD.md

# Run any idf.py operation against an explicit project.
.\scripts\esp32\dev\Invoke-Idf.ps1 -ProjectPath <path> build

# Build the production DMDClock firmware. This never flashes a device.
.\scripts\esp32\dev\Build-DmdClock.ps1

# Build the isolated 640x172 Waveshare 3.49B V2 development target.
.\scripts\esp32\dev\Build-DmdClock.ps1 -Board Waveshare349B

# Select a board and published ESP32 release, verify it, and optionally flash it.
# This is the supported end-user flashing entry point.
.\scripts\esp32\Flash-DmdClockEsp32.ps1

# Developers can flash and monitor the original Waveshare 7 local build through ESP-IDF.
.\scripts\esp32\dev\Invoke-Idf.ps1 -ProjectPath .\firmware\dmdclock-esp32 `
  -p COM5 -B build-hw-esp32 flash monitor

# Package both credential-free targets into one release directory.
.\scripts\esp32\dev\Package-DmdClockEsp32.ps1 -Board Waveshare7 -CleanOutput
.\scripts\esp32\dev\Package-DmdClockEsp32.ps1 -Board Waveshare349B

# Include both verified ESP32 targets when previewing the combined release.
.\scripts\Publish-GitHubRelease.ps1 -Tag v1.5.0 -IncludeEsp32 -WhatIf

# Generate a one-time, ignored first-flash Wi-Fi header and build with it.
# The password is entered through a masked SecureString prompt.
.\scripts\esp32\dev\Set-DmdClockBootstrapWifi.ps1 -WifiSsid 'My Wi-Fi' -Build

# After the first connection, remove the header and rebuild. A normal flash
# preserves the credentials that firmware copied into NVS.
.\scripts\esp32\dev\Clear-DmdClockBootstrapWifi.ps1 -Build

# Build and run the ESP32-S3 QEMU profile with its virtual RGB display.
.\scripts\esp32\dev\Build-DmdClockQemu.ps1
.\scripts\esp32\dev\Run-DmdClockQemu.ps1

# Run both models concurrently from separate terminals. Each uses its own build
# directory, microSD image, web port, and QEMU monitor port.
.\scripts\esp32\dev\New-DmdClockQemuSdImage.ps1 -ScenesFolder .\scenes `
  -OutputPath .\firmware\dmdclock-esp32\dmdclock-qemu-sd-waveshare7.img
.\scripts\esp32\dev\New-DmdClockQemuSdImage.ps1 -ScenesFolder .\scenes `
  -OutputPath .\firmware\dmdclock-esp32\dmdclock-qemu-sd-landscape349.img
.\scripts\esp32\dev\Run-DmdClockQemuModel.ps1 -Model Waveshare7
.\scripts\esp32\dev\Run-DmdClockQemuModel.ps1 -Model Landscape349 -SkipBuild

```

`Flash-DmdClockEsp32.ps1` is the supported end-user flashing command. Its menu
selects the exact hardware first and then shows only compatible published
releases. It verifies target metadata and hashes, downloads and verifies a
portable official Espressif flashing tool, offers application-only or complete
flashing, and offers a separately guarded FullReset mode that erases only NVS
before a complete installation. It requires an explicit COM port and checks for
an ESP32-S3 with 16 MB flash. Application and complete modes never erase NVS;
FullReset requires `RESET`, rejects `-Force`, and leaves the microSD card untouched.

Published DMDClock images support the original Waveshare
`ESP32-S3-Touch-LCD-7`, 800×480, and the
`ESP32-S3-Touch-LCD-3.49B` V2 / Rev1.1, 640×172. Both require an
`ESP32-S3-WROOM-1-N16R8` module and have active touch controls. The 7B and
3.49B V1 remain blocked. Factory recovery requires the exact PCB revision plus
final `FLASH` confirmation and replaces internal-flash settings.
Chip detection cannot distinguish display wiring or revisions, so physical
board-label confirmation remains mandatory.

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
tracks what belongs to the selected library without deleting files from a
previous library. The script requires an existing healthy FAT32 volume and never
partitions, formats, or deletes card content.

Both entry scripts import `DmdClock.Provisioning.psm1`. Download-only staging
uses `ESP32`, `SDCard`, `Tools`, and `Logs` below one destination and atomically
maintains `staging-manifest.json`. `-Source` validates every required staged
file by size and SHA-256 before either script reaches its disk or COM gate.

`Measure-ScenePackDelivery.ps1` records the real ZIP phases from a running QEMU
profile or compares the revision-pinned ZIP with sequential downloads of every
source scene. Logs and machine-readable summaries are written below
`output\benchmarks\scene-pack-delivery`. See
[scene-pack delivery benchmark](../reports/SCENE-PACK-DELIVERY-BENCHMARK.md)
for the measured result and reproduction commands.

The vendor package is ignored by Git and stored at
`external\waveshare-esp32-s3-touch-lcd-7`. Its downloaded archive has SHA-256
`5351D443EAA605CAB1EB80D050D867C18E1CE2B33C9CBC78AAE1B7BCA040B038`.

QEMU needs the 64-bit MSYS2 `libiconv` runtime at
`C:\msys64\mingw64\bin\libiconv-2.dll`. The runner adds that directory only to
its child process environment; it does not copy DLLs into Windows.

`Run-DmdClockQemuModel.ps1` launches two board profiles: `Waveshare7`
(800×480, DMD 6×) and `Landscape349` (640×172, DMD 5×). The smaller
`Landscape349` profile is also the geometry-validation target. Its compact
controls and information row are temporary overlays, leaving the complete
640×160 DMD unobstructed when the controls are hidden. `Waveshare7` uses
`dmdclock-qemu-sd-waveshare7.img`, web port 8080, and monitor port 4444.
`Landscape349` uses `dmdclock-qemu-sd-landscape349.img`, web port 8081, and
monitor port 4445. These separate resources allow both profiles to run at the
same time. Override them with `-SdImage`, `-WebPort`, or `-MonitorPort`. If the
model's default image does not exist and no explicit image is supplied, QEMU
boots with the deterministic 11-scene embedded fallback.

After a model is running, validate its actual framebuffer and record PPM/hash
evidence:

```powershell
.\scripts\esp32\tests\Test-DmdClockQemuDisplay.ps1 `
  -Model Landscape349 `
  -QemuUrl http://127.0.0.1:8081 `
  -MonitorPort 4445
```

The gate waits until the network startup view has ended, verifies `/api/state`,
captures the HMP framebuffer, checks the exact model resolution and P6 payload,
rejects a blank frame, and writes JSON evidence under
`output\esp32\reports\qemu-display`.

`Test-DmdClockPhysical349B.ps1` builds and runs the separate Waveshare 3.49B V2
panel diagnostic. It verifies the connected ESP32-S3, 8 MB PSRAM, 16 MB flash,
and generated image hashes before requesting `FLASH`, then validates serial
progress through red, green, blue, black, white, and grid stages. Use a
one-minute smoke test first and `-DurationMinutes 20` for the P5 soak gate.
Visual orientation, RGB order, tearing, and corruption still require observing
the physical LCD. On V2, GPIO42 is an active-low brightness input: low is full
brightness and high blanks the backlight.

`Test-DmdClockPhysical349BApp.ps1` builds and flashes the isolated production
DMDClock target after validating the V2 board and image geometry. It records
boot, native SDMMC, scene-index, panel-init, and ready-state evidence, rejects
watchdog/crash/persistence failures, and leaves the P6 visual checklist explicit:

```powershell
.\scripts\esp32\tests\Test-DmdClockPhysical349BApp.ps1 -Port COM5 `
  -BoardRevision V2 -ConfirmHardware 3.49B -DurationMinutes 1
```

The P7 image enables AXS15231B touch on the 3.49B V2. Its final landscape
orientation and all eight visible menu controls passed the physical P7 gate.

`Test-DmdClockPhysicalFonts.ps1` runs the reusable v1.6 physical font matrix
against a flashed board's live API. It exercises all five fonts across 12/24-hour
and seconds combinations, rejects an unknown font, checks frame advancement,
scene playback, memory and touch/settings diagnostics, performs a real reboot
persistence test, restores the initial settings, and records JSON evidence. Pass
`-VisualConfirmation ALL-FONTS-OK` only after observing all five choices:

```powershell
.\scripts\esp32\tests\Test-DmdClockPhysicalFonts.ps1 `
  -DeviceUrl http://192.168.1.150 -Board Waveshare349B `
  -VisualConfirmation ALL-FONTS-OK
```

`Test-DmdClockQemuAcceptance.ps1` exercises the broader QEMU behavior matrix:
clock, static/animated SCNs, all four color families, brightness, QR/touch
overlays, random automatic playback, and active schedule-off evaluation. It
records per-case framebuffer/hash evidence under
`output\esp32\reports\qemu-acceptance` and restores the original settings.

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
