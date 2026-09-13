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
- Scene intensity mapping is visually accepted: scenes have substantially better
  colouring on the display.
- Windows installation, ESP32 PowerShell provisioning (including system-disk
  rejection), and physical ESP32 resilience are accepted. This includes card
  fault handling, power recovery, rendering, touch/web responsiveness, NTP,
  persistence, and soak behavior.
- The webpage already presents API-backed diagnostics through `/api/state`.
  Script-based scene preparation/copy provides the required local scene import.

## Want to do now

### P0 — browser authentication finish

- Browser authentication works, but same-browser session handoff is slow and
  not fully complete. Prioritize finishing and accepting this flow.

## Deferred roadmap

- Revisit package/hash release checks when a release is being prepared.
- macOS public-release work is deferred because Apple signing/notarization cost
  is the current stopper; the unsigned developer preview remains available.
- Consider weather and time features for Windows, macOS, and both supported
  ESP32 boards.

## Rules for closing work

- Build, unit, QEMU, serial, and HTTP evidence does not replace physical-panel
  or browser acceptance when that is the stated gate.
- Keep raw SCN files unchanged. Treat unverified intensity metadata as absent.
- Use `FullReset` or board-specific factory recovery to reset forgotten web
  credentials. Ordinary application or full flashing preserves NVS and does not
  reset them.
- Update this file after a meaningful implementation, validation, flash, or
  blocker; move an item to **Done** only with its relevant evidence.
