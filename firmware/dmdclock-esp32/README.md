# DMDClock ESP32-S3 firmware

Source, documentation, and releases:
[DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32).

This firmware targets the original Waveshare
`ESP32-S3-Touch-LCD-7`:

- fixed 800×480 RGB panel timing and pin mapping from the official Waveshare
  ESP-IDF example;
- centered 128×32 DMD rendered at an exact 6× scale;
- eight fixed Basic colours, eight horizontal Gradients, and sixteen vertical
  C64-inspired Raster themes on black, plus a persistent Custom option in every
  colour family;
- integer Plasma animation with eight palettes plus Custom, persistent 1–60
  second cycle timing, and startup reference-vector validation;
- optimized per-dot glow with persistent 0–100% halo strength;
- complete SD-card scene discovery from `/dmd/scenes` with original SCN timing;
- Windows-style one-shot scenes, clock layers, automatic cycling, random order,
  configurable scene count, and gaps;
- large 5×7 clock digits, optional seconds, and 12/24-hour display;
- persistent brightness, clock, timezone, and Wi-Fi settings in NVS;
- editable settings backup at `/dmd/config/settings.json`, loaded at boot and
  mirrored with NVS after every web change;
- compact one-row scene metadata with grey, follow-theme, or custom colouring;
- persistent weekly screen-off painting and a weekly weekday/time reboot
  appointment with reboot-loop protection;
- an always-available `DMDClock-xxxx` access point and embedded web remote with
  default-on LAN source-address filtering;
- browser time fallback plus automatic and manual NTP synchronization;
- GT911 touch buttons for next pinball, next scene, colour family, next theme,
  information, glow, and NTP check, plus an on-demand guided touch test;
- optional bounded `/dmd/logs/playback.log` recording of timestamped scene and
  theme events;
- web/API diagnostics for approximate chip temperature, Wi-Fi RSSI, heap/PSRAM,
  SD capacity, settings backup, flash/CPU, reset/boot, rendering, NTP, and touch;
- a one-hour temporary wake override whenever the physical screen is pressed,
  even during a scheduled screen-off period;
- an eight-second transient touch-button row with a short fade and safe
  reveal-only first touch after it has hidden.

It does not yet include OTA, Home Assistant, web authentication, or HTTPS.
Proprietary scene files are not embedded in production firmware or tracked by Git.

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
in device NVS under the current settings design; NVS encryption is a
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
It checks GitHub once per browser page load and shows a release link only when a
newer semantic version is available. An offline check fails silently.
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

The recovery network uses WPA2 password `dmdclock`. This controls who can join the
access point; it is not a web login. The HTTP server has no account password or
TLS. **LAN-only web access** defaults to enabled and accepts only the ESP32's
current station/AP subnets, loopback, or link-local clients for every page and
API route. It still trusts devices already on those LANs. The switch is in
**Time and network**, persists in NVS and `/dmd/config/settings.json`, and should
remain on unless a trusted firewall provides an equivalent boundary. Never
forward device port 80 from the internet.

Remote controls:

- any available embedded/TF-card scene, or clock content;
- Windows-style sequential/random clock and scene cycles;
- screen on/off;
- brightness from 0–100%;
- all 32 Basic, Gradient, and Raster presets plus animated Plasma;
- eight Plasma palettes plus Custom, four RGB stops, and 1–60 second cycle speed;
- 12/24-hour time;
- seconds on/off;
- animation information on/off, applied immediately when its checkbox changes;
- matching quick buttons for next pinball, next scene, colour family, next
  family theme, information, NTP, glow, and return to clock;
- a confirmation-protected device reboot button and matching `reboot` action
  through `POST /api/action`;
- a glow-strength slider with a matching transient touchscreen toggle;
- timezone;
- home Wi-Fi name and password;
- live device time, browser drift, NTP source/status, exact last sync and age;
- effective screen On/Off state, including manual, weekly-schedule, and
  temporary touch-wake reasons;
- automatic/manual NTP plus immediate browser-time fallback.

The remote footer links to the device-hosted API reference at `/api-docs`. It
documents the live state and scene-catalog reads, partial persistent settings
updates, named control actions, browser-time fallback, accepted values, and
example requests. The current API has no authentication or HTTPS and is intended
only for a trusted local network; the default-on LAN source filter applies to it.

## Secondary-storage layout

The prepared card tree is under [`sdcard/dmd`](sdcard/dmd). Copy that `dmd`
directory to the root of the microSD/TF card so the device sees `/dmd`.

### Prepare a card from PowerShell

After formatting the card as FAT32, run the idempotent preparation script from
the repository root. Replace `F` with the card's drive letter:

```powershell
# Preview validation, downloads, and proposed card changes.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F -WhatIf

# Prepare or repair the card.
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -DriveLetter F
```

The script never formats a volume. It refuses the Windows system volume,
requires FAT32, requires a removable volume by default, checks health and free
space, validates every SCN with `DmdClock.Tools`, and installs the complete
DotClk set under `/dmd/scenes`. It also creates the canonical `/dmd` directory
tree, installs `scene-metadata.json`, and writes a deterministic SHA-256 content
manifest under `/dmd/config`.

Running the same command again is safe: matching files remain untouched,
missing files are added, damaged managed files are repaired, changed metadata
is updated, and unrelated user scenes are preserved. The final summary reports
`Unchanged`, `Added`, `Repaired`, `Updated`, and `Preserved` counts. Use
`-RefreshSource` to replace the locally cached upstream archive. Some USB card
readers report media as a fixed disk; after checking the drive letter carefully,
use `-AllowFixedDrive` for those readers.

At boot, firmware gives the card three bounded mount attempts. Between attempts
it resets the board's TF enable line and waits briefly for the card to settle.
This recovers cards left in a stale SPI state by a soft reset or reflash; after
three failures the device continues safely in clock-only mode and never formats
the card.

The firmware creates `/dmd/config/settings.json` after boot. It is normal,
formatted JSON that can be backed up or edited on a PC while the card is removed
from the clock, and it takes priority over NVS at the next boot. A complete
network restore requires the file to contain the Wi-Fi password in plain text,
so protect the card and any copied settings file.

The layout reserves subdirectories for scenes, fonts, Plasma assets, extended
web assets, exported configuration, backups, bounded logs, rebuildable caches,
and verified downloads. Production firmware now attempts a non-fatal SPI mount,
indexes every flat `.scn` file from `/dmd/scenes` in PSRAM, and stays in clock-only
mode when the card or folder has no valid scenes. Place the shared
`scenes/scene-metadata.json` beside the SCN files as
`/dmd/scenes/scene-metadata.json`. Windows and ESP32 then apply the same exact
file overrides and longest-prefix rules for titles, games, manufacturers, and
years. SCN storyboard data remains authoritative for playback timing, masks,
blanking, and clock placement.

Boot-critical firmware, NVS settings and secrets, a minimal recovery page, and
one fallback bitmap font stay in internal flash. Production firmware contains
no SCN files.

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

The production ESP32-S3 build embeds no scenes and uses only `/dmd/scenes` on
the TF card. The live prepared card currently indexes all 2,324 SCNs; QEMU alone
retains the deterministic 11-scene projection. If no SD-card scene is available,
production remains in clock mode.
Required QEMU inputs fail configuration clearly when absent. The SCNs remain
ignored by Git and are intended for local decoder and playback testing. Do not
publish or redistribute a firmware or card image containing them unless every
scene's distribution rights have been confirmed.

## Current verification boundary

The production ESP32-S3 and QEMU profiles compile locally with ESP-IDF 5.5.2.
The exact 800×480 N16R8 board has been flashed through COM4 and live checks cover:

- RGB output, CH422G backlight control, double-buffered PSRAM rendering, and the
  vendor 16 MHz pixel-clock baseline;
- GT911 event reporting, orientation, guided test, and the transient overlay;
- access-point/station networking, NTP, persistent settings, and local HTTP API;
- FAT32 mounting, all 2,324 prepared scenes, shared metadata, and playback log;
- browser controls, effective screen-state reporting, and API-initiated reboot.

Still required are extended soak testing, quantified flicker/frame diagnostics,
every-theme and every-touch-target coverage, card-removal/corruption tests,
factory recovery, authentication, and OTA.
