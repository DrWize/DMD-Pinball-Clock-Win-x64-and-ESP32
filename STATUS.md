# DMDClock status

Last consolidated: 2026-09-13. This is the active project record. Historical
detail, completed checklists, prior release notes, and superseded plans are in
[`docs/legacy/`](docs/legacy/).

## Done

- Windows application: SCN decoding, clock compositor, scene review, settings,
  local AppData storage, portable/standalone packages, screensaver support, and
  installer validation are established.
- Shared scene libraries: DMD-Large (2,416 scenes) and DotCLK-Orig (2,324
  scenes) have a tracked `scene-metadata.json` baseline and ESP32 card support.
- ESP32-S3: Waveshare 7 and 3.49B V2 / Rev1.1 targets build, support the DMD
  renderer, card scenes, web settings, touch, NTP, Wi-Fi, and release packaging.
  QEMU remains an automated integration gate rather than panel acceptance.
- Scene intensity metadata: all 2,416 DMD-Large file entries were enriched on
  2026-09-12 with verified hashes, frame counts, raw levels, and evenly-spaced
  mappings. Windows reader tests cover a verified and hash-stale record.
- ESP32 intensity runtime: schema-1 parsing, SCN hash/frame-count/value-mask
  verification, and 16-level lookup-table conversion are implemented. Windows
  Scene Reviewer supplies a verified mapped preview; normal Windows playback is
  deliberately unchanged.

## Want to do now

### P0 — acceptance blockers

- Complete direct physical-panel intensity verification on both supported boards,
  including a serial `Verified intensity mapping` record and visual comparison.
- Complete same-browser first setup, logout, login, and authenticated API checks
  on both boards. Browser session handoff remains open despite prior controlled
  HTTP checks.
- Implement and hardware-test transport-aware, credential-only serial recovery.
  Do not claim `auth reset` support until it works without destabilising either
  console transport.

### P1 — release confidence

- Complete the Windows manual release checklist, including read-only install,
  screensaver modes, damaged SCNs, settings persistence, and package hashes.
- Exercise ESP32 non-destructive provisioning cases: no hardware, offline
  staging, bad downloads, multiple removable disks/COM ports, cancellation, and
  system-disk rejection.
- Physically test card removal, full/corrupt cards, power loss, rendering,
  touch/web responsiveness, NTP, persistence, and one-hour soak behavior.
- Validate macOS launch, rendering, menus, displays, scene selection, and
  settings on physical Apple Silicon. Signing/notarization remains a separate
  approval and delivery task.

### P2 — next product work

- Add scene/game browsing, search, bulk selection, playback history, and
  reliable metadata-update delivery with offline fallback.
- Add diagnostics for scene/frame/timing errors and display/CPU/PSRAM metrics.
- Add safe scene upload/import and authenticated, redacted live-log/statistics
  facilities for ESP32.
- Improve scheduling, multi-display behavior, transitions, burn-in protection,
  weather, and additional clock layouts.

## Rules for closing work

- Build, unit, QEMU, serial, and HTTP evidence does not replace physical-panel
  or browser acceptance when that is the stated gate.
- Keep raw SCN files unchanged. Treat unverified intensity metadata as absent.
- Update this file after a meaningful implementation, validation, flash, or
  blocker; move an item to **Done** only with its relevant evidence.
