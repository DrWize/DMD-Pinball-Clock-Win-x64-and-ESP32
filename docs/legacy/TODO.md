# DMDClock development TODO

This file contains unfinished work only. Completed implementation and decision
records are archived in [`docs/development/DEVELOPMENT-HISTORY.md`](docs/development/DEVELOPMENT-HISTORY.md).

Current stable release: **v1.7.2**. Supported embedded targets are the original
Waveshare ESP32-S3-Touch-LCD-7 (800×480, N16R8) and the 3.49B V2 /
Rev1.1 (640×172, N16R8). The 7B and 3.49B V1 remain incompatible.

## Shared

### Priority 1 — release validation and robustness

- [ ] Ensure startup and normal operation never require write access beside the executable
- [ ] Consider trimming only after the untrimmed standalone build passes all release tests

### Priority 3 — animation-library selection - Future

- [ ] Add manufacturer → game → animation browsing with search
- [ ] Add `Select all`, `Clear all`, and `Reset`
- [ ] Support all enabled animations, manufacturer, game, random, sequential,
      and chronological playback modes
- [ ] Add focused migration, persistence, and playback-selection tests

### Main application selection

- [ ] Add a dedicated **Choose games and scenes…** window to the main DMDClock
      application, opened from the context menu without cluttering the clock display
- [ ] Show enabled games and the allowed scenes for the selected game side by side,
      with search, per-game scene counts, and `Select all`, `Clear all`, and `Reset`

### Metadata packaging and GitHub updates

- [ ] Load metadata in layers: bundled baseline, newer validated GitHub update, then
      optional library-local overrides, with later layers overriding matching entries
- [ ] Add a versioned GitHub metadata manifest containing schema version, metadata
      version, publication time, download URL, and SHA-256 checksum
- [ ] Add a GitHub issue form for metadata additions and corrections requiring game,
      exact machine/version, release year, affected files or RD range, and a reliable
      evidence link; only reviewed data may enter the published metadata
- [ ] Add packaging, precedence, offline fallback, checksum failure, schema migration,
      concurrent reload, and clean-build metadata tests

### Priority 4 — display and daily operation

- [ ] Select and persist the target monitor
- [ ] Recover gracefully when the selected monitor is disconnected
- [ ] Add a discreet paused indicator
- [ ] Add explicit enable/disable settings for clock, date, and animations
- [ ] Add an optional weekday display
- [ ] Add a system-tray icon with pause, show clock, next animation, and exit
- [ ] Resume the last safe mode after restart or power failure
- [ ] Export/import settings and create an automatic pre-migration backup
- [ ] Add a diagnostics view for file, frame, timing, resolution, and decoder errors
- [ ] Add silent fullscreen error handling that logs and skips broken content

### Animations and library

- [ ] Avoid replaying an animation until the active selection has been exhausted
- [ ] Playback history and temporary `Do not show again`
- [ ] Per-animation duration, repeat count, and short-animation looping
- [ ] Custom metadata corrections, thumbnails, and duplicate-file handling
- [ ] Curate consistent names and metadata for known SCN collections


### Clock and automatic display

- [ ] Multiple clock layouts with optional seconds/date
- [ ] Blinking-colon seconds mode
- [ ] Immediate, fade, and DMD-dissolve transitions
- [ ] Active/dim/off schedules and separate day/night brightness
- [ ] Burn-in protection through small position shifts and rotating layouts
- [ ] Multiple automatically rotating time zones
- [ ] Weather integration

## Windows

### P0.1 — shared catalog and product language

- [ ] Make unavailable or incompatible packs visible but disabled with a useful
      reason; never silently substitute one pack for the other.

### Priority 1 — release validation and robustness

- [ ] For the next release candidate, complete every item in the
      manual Windows test checklist above

### Priority 2 — VS Code development setup

- [ ] Add `.vscode\extensions.json` with the required/recommended C# tooling
- [ ] Add `.vscode\tasks.json` for restore, build, test, run, compatibility scan,
      and release packaging
- [ ] Add `.vscode\launch.json` for debugging the Avalonia application
- [ ] Verify every VS Code task has an equivalent documented PowerShell command
- [ ] Add troubleshooting for SDK discovery, missing resources, bad SCN files,
      graphics problems, and locked build output

### Metadata packaging and GitHub updates

- [ ] Add **Check for metadata updates…** to the regular app and screensaver
      configuration mode; download updates over HTTPS, validate schema and checksum,
      and replace the AppData copy atomically only after complete validation
- [ ] Store downloaded metadata under `%LOCALAPPDATA%\DmdClock\metadata\`, retain the
      bundled version as an offline fallback, and retain the last known-good downloaded
      version when an update is missing, damaged, incompatible, or unavailable
- [ ] Make regular app and screensaver playback observe the same validated metadata
      update without requiring either installation directory to be writable

### Priority 4 — display and daily operation

- [ ] Add start-with-Windows and always-on-top options

### Priority 5 — installer and release automation

- [ ] Optional future: implement Authenticode signing if an affordable suitable
      option becomes available

### Manual Windows test checklist

- [ ] Extract each ZIP into a new empty directory; do not run from inside the ZIP
- [ ] Start regular `DmdClock.App.exe` and standalone `DmdClock.App.exe`
- [ ] Verify the built-in clock works with no `scenes` directory
- [ ] Select ALTERN8, FISHY, TREK, and TWILIGHT independently for time and date
- [ ] Verify 12/24-hour time, seconds on/off, and every date format
- [ ] Load valid, warned, unsupported, and damaged SCN samples
- [ ] Verify automatic cycles, pause, next/previous, metadata, and rescanning
- [ ] Switch English/Swedish and test behavior with `i18n` missing
- [ ] Verify settings and the library index are written only to AppData
- [ ] Run from a read-only installation directory
- [ ] Confirm `SHA256SUMS.txt` matches both standalone binaries
- [ ] Check startup time, temporary native extraction, and package size
- [ ] Verify `/c` opens configuration mode
- [ ] Verify `/s` opens fullscreen and exits on keyboard, click, or deliberate mouse movement
- [ ] Right-click `DMDClock.scr`, choose **Install**, and select it in Windows Screen Saver Settings
- [ ] Verify the Control Panel `/p <HWND>` preview is embedded and closes cleanly

## macOS

### P0.4 — tests and release acceptance

- [ ] Build the same Avalonia UI for Windows x64 and macOS ARM64 and verify that
      both choices are visible, correctly labelled, downloadable, selectable,
      and retained after restart.

### Priority 6 — macOS Apple Silicon application

- [ ] Validate launch, rendering, fullscreen, multiple displays, file pickers,
      Control-click menus, fonts, scenes, downloads, and settings under
      `~/Library/Application Support/DmdClock` on a physical Apple Silicon Mac.
- [ ] Join the Apple Developer Program and provision a Developer ID Application
      certificate if public friction-free distribution is approved.
- [ ] Sign nested native code and the app bundle with hardened runtime, submit it
      with `notarytool`, inspect the notarization log, staple the ticket, and test
      a quarantined download through Gatekeeper.
- [ ] Replace the preview with a signed/notarized macOS ZIP or DMG and include it
      in the platform-specific release manifest.
- [ ] Decide whether launch-at-login fullscreen mode is sufficient before
      starting a native Objective-C/Swift `ScreenSaverView` `.saver` host.

## ESP32-S3

### Release-package font checks

- [ ] Add package assertions that verify the built-in fallback plus ALTERN8,
      FISHY, TREK, and TWILIGHT in every applicable Windows, macOS, and ESP32
      release artifact. Keep Inter as a desktop-only bundle unless the separate
      measured ESP32 bitmap-conversion project is completed.

### P2.8 — non-destructive acceptance matrix and documentation

- [ ] Add verifiable tests for Windows 11 x64 with PowerShell 7; no SD card; no
      ESP32; download-only; complete offline staging; incomplete offline staging;
      multiple removable disks; multiple COM ports; unavailable GitHub; failed,
      truncated, corrupt, zero-byte, stale, and checksum-mismatched downloads;
      cancellation; invalid disk selection; topology changes; and attempts to
      select the system disk.
- [ ] Make the primary acceptance gate prove that a normal user can run staging on
      Windows 11 x64 / PowerShell 7 with no SD card and no ESP32 attached and obtain
      every required local artifact without formatting a disk or modifying
      hardware.
- [ ] Test destructive command construction only through mocks, fixtures,
      `-WhatIf`, or dry-run evidence. Automated validation and release tests must
      never perform a real format, erase, partition, or ESP32 flash.
### P0.3 — Windows-prepared ESP32 TF card

- [ ] On a physical FAT32 card, prepare and boot Original DotCLK-Orig and
      DMD-Large, confirming exact 2,324/2,416 counts and a zero-write second run.

### Hot-core glow

- [ ] Verify an all-dots-on ESP32 frame retains black separation between every dot.
- [ ] Measure the worst-case all-dots frame, Plasma, and SCN playback. Keep the
      30 FPS frame budget, touch/web responsiveness, and useful CPU, PSRAM, and
      dropped-frame diagnostics.

### ESP32-S3 web management

- [ ] Add cross-platform palette/framebuffer hashes for every Plasma palette,
      custom stops, 4-bit intensity, glow, clock, and representative SCN frames
- [ ] Verify frame time, CPU load, and touch responsiveness at 100% Hot-core glow;
      live web/API responsiveness and heap stability are already confirmed
- [ ] Quantify framebuffer handoff time and PSRAM/DMA errors, then hardware-test
      supported pixel-clock steps before accepting any value above the vendor
      baseline.
- [ ] Run physical rendering, persistence, responsiveness, and one-hour soak
      tests for Basic, Gradient, Raster, glow, clock/scene cycling, NTP, and touch
- [ ] 2026-09-12: Add first-run web setup for fixed username `admin`; the first
      user chooses a new password (minimum five characters), with no shipped
      default or displayed setup code.
- [ ] 2026-09-12: Store only a salted password verifier in a separate NVS
      namespace; use 24-hour HttpOnly authenticated sessions and CSRF protection.
      Full physical/USB recovery clears all NVS settings; a serial `auth reset`
      clears only web credentials and preserves normal settings.
- [ ] 2026-09-12: Automated ESP32 builds and dual-board flash/boot checks passed;
      browser setup/login and direct panel acceptance remain open with the user.
- [ ] 2026-09-12: **Blocked — browser login.** Both boards accept first-run
      password creation and subsequently report `configured:true`, but the
      interactive browser cannot complete sign-in. A controlled HTTP
      setup/login/authenticated-API check passed earlier, so the remaining
      gate is the browser session handoff. Do not close authentication or
      claim serial recovery works. Next: run a controlled same-browser
      setup → logout → login test using a temporary credential, verify an
      authenticated `/api/state` request, then reset credentials before user
      acceptance on both boards.
- [ ] 2026-09-12: The initial serial `auth reset` listener does not receive input
      on the current console transports. Do not use a direct UART-driver reader:
      it caused a Waveshare 7 crash and was removed. Implement and hardware-test
      a transport-aware credential-only recovery command before claiming serial reset support.
- [ ] Verify live card removal, corruption, full-card, and power-loss behavior.
- [ ] Add browser upload as an offline SCN import fallback.
- [ ] Cover catalog/archive errors, cancellation, resume, corrupt data, removed or
      full TF cards, power loss during every phase, rollback, custom-scene
      preservation, and concurrent display playback in QEMU and on Waveshare 7.
- [ ] Retain browser-to-device SCN upload as an offline fallback and automatically
      rescan the library after a successful import
- [ ] Add an authenticated browser log viewer that follows new records
      automatically using Server-Sent Events, without polling or blocking display
      rendering
- [ ] Add log level/source filters, pause/resume, search, clear-view, and download
      actions for the current and rotated log files
- [ ] Bound and rotate log storage, fall back to a RAM ring buffer when the TF card
      is unavailable, and redact Wi-Fi passwords, web credentials, session tokens,
      and other secrets
- [ ] Cover first-login enforcement, password reset, unauthorized access, failed/
      interrupted downloads, full or removed TF cards, log rotation, and live-log
      reconnects with host and hardware tests
- [ ] Measure total and per-core CPU utilization plus per-task FreeRTOS run time;
      expose frame time/FPS, dropped frames, heap/PSRAM, stack high-water marks,
      Wi-Fi RSSI, TF-card state, reset reason, and NTP state
- [ ] Add an authenticated **Statistics** web page with live cards and short
      history charts for system, temperature, memory, display, storage, network,
      time, web/MQTT, and OTA measurements
- [ ] Auto-update the Statistics page through a bounded low-rate Server-Sent
      Events stream, support pause/resume and JSON snapshot download, and ensure
      closed pages create no ongoing browser-stream work
- [ ] Track current/minimum/maximum chip temperature and configurable diagnostic
      warning thresholds only after a safe baseline is measured on the real board
- [ ] State clearly that ambient temperature, supply voltage, current, and power
      consumption require external sensor hardware and are unavailable by default
- [ ] Expose Home Assistant controls for display power, brightness, fixed color,
      mode, playlist, next/previous scene, NTP sync, and temporary DMD text
      notifications
- [ ] Expose Home Assistant diagnostic sensors for CPU, memory, frame rate,
      dropped frames, Wi-Fi, time sync, current scene, firmware, uptime, and
      TF-card capacity
- [ ] Ensure broker or Home Assistant failure never stops standalone clock,
      touchscreen, SCN playback, web settings, or local logging
- [ ] Later project: evaluate TTF/OTF font support on ESP32-S3 only after the
      bitmap-font clock, SCN playback, web interface, and performance budgets are
      stable
- [ ] For the ESP32 TTF/OTF project, compare on-device rasterization with
      build-time conversion to compact bitmap glyphs; measure flash, PSRAM, CPU,
      startup, cache, and rendering costs before choosing an implementation
- [ ] Prefer a deterministic converter that takes an approved TTF/OTF file,
      explicit point/pixel sizes, and an explicit Unicode subset, then generates a
      compact four-bit intensity atlas, masks, glyph metrics, kerning, manifest,
      and identical C++/test fixtures for ESP32
- [ ] Permit direct on-device outline rendering only if measurements demonstrate a
      material benefit over generated atlases without violating clock,
      responsiveness, memory, or recovery budgets
- [ ] Add authenticated web upload and management only for validated font files,
      enforce size/glyph limits, and preserve a built-in fallback font

