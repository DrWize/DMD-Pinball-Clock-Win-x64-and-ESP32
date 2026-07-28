# ESP32-S3 local tools

Repository:
[DrWize/DMDClock-Windows-x64](https://github.com/DrWize/DMDClock-Windows-x64).

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

# Run any idf.py operation against an explicit project.
.\scripts\esp32\Invoke-Idf.ps1 -ProjectPath <path> build

# Build the barebones DMDClock firmware. This never flashes a device.
.\scripts\esp32\Build-DmdClock.ps1

# Build and run the ESP32-S3 QEMU profile with its virtual RGB display.
.\scripts\esp32\Build-DmdClockQemu.ps1
.\scripts\esp32\Run-DmdClockQemu.ps1

# Flash the exact connected port after confirming the 800x480 N16R8 board.
.\scripts\esp32\Flash-DmdClock.ps1 -Port COM5 -Monitor
```

The vendor package is ignored by Git and stored at
`external\waveshare-esp32-s3-touch-lcd-7`. Its downloaded archive has SHA-256
`5351D443EAA605CAB1EB80D050D867C18E1CE2B33C9CBC78AAE1B7BCA040B038`.

QEMU needs the 64-bit MSYS2 `libiconv` runtime at
`C:\msys64\mingw64\bin\libiconv-2.dll`. The runner adds that directory only to
its child process environment; it does not copy DLLs into Windows.

Building does not touch connected hardware. The Windows USB-driver installer
requires an Administrator terminal; run it only if Windows does not recognize
the board automatically.
