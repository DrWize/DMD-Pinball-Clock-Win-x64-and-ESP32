# DMDClock v1.7.0

DMDClock v1.7.0 updates Windows, macOS, and both supported ESP32-S3 boards from
one source revision.

## Highlights

- Adds `RUNME-Install-DmdClockEsp32.ps1` as the preferred ESP32 installation and
  update entry point, published directly with the release.
- Adds guarded ESP32 settings reset and FullReset installation modes without a
  full-chip erase or microSD card modification.
- Adds hardware probing, stricter serial-port identity checks, verified offline
  staging, and expanded provisioning tests.
- Includes Windows installer, portable and standalone packages, an unsigned
  Apple Silicon macOS DMG, and firmware for both supported Waveshare displays.

## ESP32 Update

Download `RUNME-Install-DmdClockEsp32.ps1` from this release, then run:

```powershell
.\RUNME-Install-DmdClockEsp32.ps1 -Update -Wizard
```

Supported boards are the Waveshare ESP32-S3-Touch-LCD-7 (800x480, N16R8) and
ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1 (640x172, N16R8). The 7B and 3.49B V1 are
not compatible.
