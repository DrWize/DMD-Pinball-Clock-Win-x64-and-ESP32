# DMDClock ESP32-S3 barebones firmware

Source, documentation, and releases:
[DrWize/DMDClock-Windows-x64](https://github.com/DrWize/DMDClock-Windows-x64).
The firmware stays on the `test/esp32-s3` branch until physical-board testing is
complete.

This is the first working firmware slice for the original Waveshare
`ESP32-S3-Touch-LCD-7`:

- fixed 800×480 RGB panel timing and pin mapping from the official Waveshare
  ESP-IDF example;
- centered 128×32 DMD rendered at an exact 6× scale;
- eight fixed Basic colours, eight horizontal Gradients, and sixteen vertical
  C64-inspired Raster themes on black, with dim unlit dots;
- integer Plasma animation with eight palettes plus Custom, persistent 1–60
  second cycle timing, and startup reference-vector validation;
- optimized per-dot glow with persistent 0–100% halo strength;
- local playback of GOT06 plus ten varied SCN test scenes with original timing;
- Windows-style one-shot scenes, clock layers, automatic cycling, random order,
  configurable scene count, and gaps;
- large 5×7 clock digits, optional seconds, and 12/24-hour display;
- persistent brightness, clock, timezone, and Wi-Fi settings in NVS;
- persistent weekly screen-off painting and a weekly weekday/time reboot
  appointment with reboot-loop protection;
- an always-available `DMDClock-xxxx` access point and embedded web remote;
- browser time fallback plus automatic and manual NTP synchronization;
- GT911 touch buttons for previous/next colour, information, glow, and NTP sync;
- a one-hour temporary wake override whenever the physical screen is pressed,
  even during a scheduled screen-off period;
- an eight-second transient touch-button row with a short fade and safe
  reveal-only first touch after it has hidden.

It deliberately does not include OTA, Home Assistant, or unvalidated physical
TF-card claims.

## Fixed hardware target

Do not flash this build onto the 1024×600 `ESP32-S3-Touch-LCD-7B`. The RGB timing
and GPIO map target only the original 800×480 board. Before flashing, confirm the
labels:

```text
ESP32-S3-Touch-LCD-7
ESP32-S3-WROOM-1-N16R8
```

Keep the archived factory image available so the board can be restored at address
`0x0`.

## Build

The project uses the pinned workspace-local ESP-IDF 5.5.2 toolchain:

```powershell
.\scripts\esp32\Build-DmdClock.ps1
```

The application binary is written to:

```text
firmware\dmdclock-esp32\build\dmdclock_esp32.bin
```

Building does not access, reset, erase, or flash a connected device.

## First-flash Wi-Fi bootstrap

For initial board preparation, generate a local, Git-ignored bootstrap header.
The SSID is supplied explicitly and the password is requested as a masked secure
prompt:

```powershell
.\scripts\esp32\Set-DmdClockBootstrapWifi.ps1 `
  -WifiSsid 'My Wi-Fi' `
  -Build
```

The production build embeds those credentials once. On first boot, firmware
copies them into the existing `dmdclock` NVS settings namespace before starting
the station connection. It never logs the password. QEMU always disables this
header, even when it exists locally.

After the board connects successfully:

```powershell
.\scripts\esp32\Clear-DmdClockBootstrapWifi.ps1 -Build
.\scripts\esp32\Flash-DmdClock.ps1 -Port COM5
```

The normal application flash preserves NVS, so Wi-Fi continues using the saved
credentials while the rebuilt application image no longer contains the
bootstrap copy. Do not erase NVS during that cleanup flash. The password remains
in device NVS under the current barebones settings design; NVS encryption is a
later security gate.

## Run in QEMU

Build the separate emulator profile. It uses QEMU's ESP32 CPU model because the
virtual RGB MMIO device currently stalls on the ESP32-S3 model; the production
profile remains ESP32-S3:

```powershell
.\scripts\esp32\Build-DmdClockQemu.ps1
```

Then start the emulator, virtual RGB panel, and serial monitor:

```powershell
.\scripts\esp32\Run-DmdClockQemu.ps1 -SkipBuild
```

Open `http://localhost:8080/` for the web remote. The virtual display is useful
for validating the shared SCN decoder, timing, classic-color renderer, settings
API, and browser UI. It does not validate ESP32-S3-specific instructions or
emulate the Waveshare panel wiring, CH422G backlight controller, PSRAM, touch
hardware, or Wi-Fi radio behavior.

The web remote footer links to the same canonical GitHub repository so source,
documentation, issues, and releases are reachable from the device interface.
QEMU records and reports a due scheduled reboot without calling `esp_restart()`
because its emulated network adapter does not recover from an in-process reset.
The production ESP32-S3 build performs the real restart.

## Flash

Connect a data-capable USB cable to the port labeled `UART`, then discover the
port:

```powershell
.\scripts\esp32\Doctor.ps1
```

After verifying the physical board model, flash an explicit port:

```powershell
.\scripts\esp32\Flash-DmdClock.ps1 -Port COM5
```

Add `-Monitor` to keep the serial log open after flashing:

```powershell
.\scripts\esp32\Flash-DmdClock.ps1 -Port COM5 -Monitor
```

The flash operation writes the bootloader, partition table, and application. It
does not run unless an explicit connected COM port is supplied.

## First start and remote control

1. Wait for the board to show the orange DMD clock. Before time is synchronized,
   it shows `--:--`.
2. Join the Wi-Fi network named `DMDClock-xxxx`.
3. Use password `dmdclock`.
4. Open `http://192.168.4.1/`.
5. The browser supplies the current time automatically.
6. Optionally enter home Wi-Fi credentials and select a timezone, then save.

The access point remains enabled after home Wi-Fi connects, providing a recovery
path if home-network settings are wrong. The remote reports the home-network IP
when connected. SNTP uses `pool.ntp.org` and `time.cloudflare.com`.

Remote controls:

- any available embedded/TF-card scene, or clock content;
- Windows-style sequential/random clock and scene cycles;
- screen on/off;
- brightness from 0–100%;
- all 32 Basic, Gradient, and Raster presets plus animated Plasma;
- eight Plasma palettes plus Custom, four RGB stops, and 1–60 second cycle speed;
- 12/24-hour time;
- seconds on/off;
- animation information on/off;
- matching quick buttons for colour previous/next, information, NTP,
  glow, scene previous/next, and return to clock;
- a glow-strength slider with a matching transient touchscreen toggle;
- timezone;
- home Wi-Fi name and password;
- live device time, browser drift, NTP source and status;
- automatic/manual NTP plus immediate browser-time fallback.

## Secondary-storage layout

The prepared card tree is under [`sdcard/dmd`](sdcard/dmd). Copy that `dmd`
directory to the root of the microSD/TF card so the device sees `/dmd`.

The layout reserves subdirectories for scenes, fonts, Plasma assets, extended
web assets, exported configuration, backups, bounded logs, rebuildable caches,
and verified downloads. Production firmware now attempts a non-fatal SPI mount,
loads the known scene set from `/dmd/scenes` into PSRAM, and falls back to one
small internal scene when the card is unavailable. Place the shared
`scenes/scene-metadata.json` beside the SCN files as
`/dmd/scenes/scene-metadata.json`. Windows and ESP32 then apply the same exact
file overrides and longest-prefix rules for titles, games, manufacturers, and
years. SCN storyboard data remains authoritative for playback timing, masks,
blanking, and clock placement. This path compiles but still requires the
physical board and card for validation.

Boot-critical firmware, NVS settings and secrets, a minimal recovery page, one
fallback bitmap font, and a small fallback scene stay in internal flash.

## Test-scene boundary

The QEMU build embeds these local files:

```text
got06.scn
afm01.scn
RD0868.scn
RD0959.scn
RD1116.scn
RD1385.scn
RD1448.scn
RD1474.scn
RD1695.scn
RD1701.scn
RD1891.scn
```

The production ESP32-S3 build embeds only `RD1695.scn` as a small boot-safe
fallback and expects the full known set under `/dmd/scenes` on the TF card.
Required QEMU inputs fail configuration clearly when absent. The SCNs remain
ignored by Git and are intended for local decoder and playback testing. Do not
publish or redistribute a firmware or card image containing them unless every
scene's distribution rights have been confirmed.

## Current verification boundary

The production ESP32-S3 profile and the ESP32 simulation profile both compile
locally with ESP-IDF 5.5.2. Hardware behavior still needs to be verified on the
exact board for:

- RGB color order and panel stability;
- CH422G backlight control;
- GT911 detection, touch orientation, and touch-button hit targets;
- PSRAM framebuffer operation;
- UART flashing and serial logs;
- access-point and station networking;
- a one-hour clock/display soak.

Those checks cannot be claimed from a host-only build.
