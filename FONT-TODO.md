# ESP32 microSD Font Loading

This plan covers ESP32-only loading and use of DotClk version 1 `.fnt` files
from `/dmd/fonts` on the microSD/TF card. The Windows and macOS font systems are
out of scope except for shared rendering goldens.

## First-release contract

- [x] Scan `/sd/dmd/fonts` once at boot; changing files requires a reboot.
- [x] Keep built-in 5x7 as the only font stored in firmware.
- [x] Install ALTERN8, FISHY, TREK, and TWILIGHT through SD-card preparation.
- [x] Return valid fonts only through the API and web selector.
- [x] Defer browser upload, deletion, recursive discovery, and manual rescan.
- [x] Preserve a missing requested font ID while safely rendering built-in 5x7.
- [x] Keep an already loaded font in RAM if the card is removed; reassess it at
      the next boot.

## Runtime discovery and parser

- [x] Define `DMD_STORAGE_FONTS` as `/sd/dmd/fonts` and create it in every mount
      branch.
- [x] Scan regular top-level `.fnt` files case-insensitively; ignore hidden,
      temporary, subdirectory, and unsupported entries.
- [x] Validate version, .NET string framing, UTF-8 name, ASCII/unique glyphs,
      glyph metrics, atlas dimensions, four-bit intensities, one-bit mask,
      complete payload, and absence of trailing data.
- [x] Require `0`–`9`, `:`, `A`, `M`, and `P`; retain renderer-generated space,
      `.`, `-`, and `/` fallbacks.
- [x] Enforce 32 catalogued fonts, 128 scanned candidates, 96 KiB per file,
      256 glyphs, 255-pixel glyph width, 4096-pixel atlas width, 32-pixel height,
      63-byte names, and 127-byte filenames.
- [x] Normalize stable lowercase/hyphen IDs, reserve `builtin-5x7`, sort by
      display name and filename, and deterministically reject duplicate IDs.
- [x] Keep metadata in the boot catalog and load only the selected atlas,
      preferring PSRAM with a bounded heap fallback.
- [x] Parse outside the renderer and use a mutex-protected active-asset swap.
      The display path performs no card I/O.

## Settings and compatibility

- [x] Persist a bounded string font ID in NVS and `settings.json`.
- [x] Migrate legacy numeric NVS values 0–4 to `builtin-5x7`, `altern8`,
      `fishy`, `trek`, and `twilight`.
- [x] Initialize storage and the font catalog before settings and display.
- [x] Allow unavailable persisted IDs at boot, expose fallback state, and keep
      unrelated settings intact.
- [x] For live changes, load and activate only an ID in the valid boot catalog;
      reject failures without changing the persisted or active font.
- [x] Remove generated DotClk C assets and their firmware build integration.

## Web server and UI

- [x] Add `GET /api/fonts` with `id`, `name`, `source`, and SD `filename`.
- [x] Extend `/api/state` with requested ID, active ID/name, fallback flag, and
      concise fallback error.
- [x] Keep `POST /api/settings` as the font-selection interface and return HTTP
      400 for unavailable or unloadable font IDs.
- [x] Populate the selector from `/api/fonts`, select the active font, and show
      fallback/reboot guidance without listing rejected files.
- [x] Update the embedded API reference and ESP32 setup documentation.

## Packaging

- [x] Copy the four canonical fonts by default in local, online, staged, and
      offline SD-card preparation workflows.
- [x] Verify hashes, preserve unrelated fonts, preserve and warn about a
      differing same-name user font, and make a matching second run zero-write.
- [x] Include the canonical font directory in generated QEMU FAT32 images.

## Verification

- [x] Host-test all canonical files through the runtime C parser.
- [x] Reject truncation, trailing data, unsupported versions, malformed UTF-8,
      duplicate glyphs/IDs, oversized files, and traversal-like filenames.
- [x] Compare runtime-loaded fonts with all existing 128x32 intensity/mask
      golden frames.
- [x] Verify `/api/fonts`, selection, rejection, active/fallback reporting, and
      distinct framebuffer hashes on both QEMU display models.
- [x] Verify SD preparation add/preserve/idempotence behavior through the
      acceptance test suite.
- [x] Build both Waveshare hardware targets.
- [ ] On both physical boards, confirm visible output, switching, reboot
      persistence, no-card fallback, card removal behavior, and stability.

Physical checks require flashed hardware and visible confirmation; QEMU output
must not be reported as physical proof.
