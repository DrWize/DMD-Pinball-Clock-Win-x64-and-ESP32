# DMDClock v1.7.1

DMDClock v1.7.1 rebuilds Windows, macOS, and both supported ESP32-S3 boards
from one source revision and updates the ESP32 provisioning workflow released
with v1.7.0.

## Highlights

- Adds a startup menu to `RUNME-Install-DmdClockEsp32.ps1` for microSD card
  preparation, firmware flashing, settings reset, download-only staging, and
  complete installation or update.
- Adds the settings-reset script to the self-fetching installer companions.
- Improves board probing, serial-port handling, cancellation, download
  recovery, FullReset behavior, and provisioning error reporting.
- Expands automated coverage for the ESP32 installation and recovery paths.
- Includes Windows installer, portable and standalone packages, an unsigned
  Apple Silicon macOS DMG, and firmware for both supported Waveshare displays.

## ESP32 Update

Download `RUNME-Install-DmdClockEsp32.ps1` from this release and run it without
arguments for the interactive menu, or use the documented command-line options
for unattended and dry-run workflows.

Supported boards are the Waveshare ESP32-S3-Touch-LCD-7 (800x480, N16R8) and
ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1 (640x172, N16R8). The 7B and 3.49B V1 are
not compatible.
