# Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO

## Goal and scope

Add the **Waveshare ESP32-S3-Touch-LCD-3.49B** as a second first-class
ESP32-S3 hardware target without forking the DMDClock application logic.

The logical DMD framebuffer remains permanently **128×32** on every target:

| Target | Framebuffer | DMD scale | Rendered DMD | Position |
| --- | ---: | ---: | ---: | ---: |
| Waveshare 7 | 800×480 | 6× | 768×192 | centered |
| Waveshare 3.49B | 640×172 landscape | 5× | 640×160 | `x=0`, `y=6` |

Both boards must share the same SCN files, scene metadata, clock renderer,
colorization, Plasma implementation, settings model, web API, and playback
logic. Do not create board-specific scene formats or separate scene libraries.

`Landscape349` QEMU is the required validation gate before any DMDClock image
is flashed to the physical 3.49B. QEMU proves shared rendering, memory pressure,
settings, storage, and web behavior; it does not prove the ESP32-S3 panel bus,
timing, pins, touch controller, PSRAM mode, or physical stability.

## Current baseline

- [x] Define separate `Waveshare7` and `Landscape349` QEMU profiles with
      independent build directories, writable SD images, web ports, and HMP
      ports.
- [x] Configure `Landscape349` as 640×172 with a 5× DMD scale.
- [x] Run both QEMU profiles concurrently with 2,416-scene images and persistent
      settings.
- [x] Reserve the Waveshare 3.49B choice in the flashing workflow without
      allowing a Waveshare 7 image to be substituted.
- [x] Qualify the exact physical Waveshare 3.49B as V2 / Rev1.1 and prove its
      matching factory-recovery image.
- [ ] Publish the validated board-specific DMDClock firmware image in v1.5.0.

The completed baseline above is infrastructure evidence only. It does not mark
the ordered port gates below as accepted.

## Current P status

| Phase | Status | Remaining gate |
| --- | --- | --- |
| P0-P4 | Complete | None. Display contract, QEMU model, layout, backend boundary, exact V2 identification, and factory recovery are proven. |
| P5 | Complete | The corrected illuminated 20-minute panel soak passed all stages without a detected crash. |
| P6 | In progress | Run the explicit synthetic 128x32 pattern and close the representative physical-to-QEMU comparison. Animation, clock, static SCN, colors, and the web-triggered information row are accepted. |
| P7 | Complete | Corrected touch coordinates and all eight visible controls passed physical button-map capture. |
| P8 | Not started | Run the complete regression matrix on both physical board targets. |
| P9 | In progress | Produce, validate, publish, and download-check both separate recoverable release packages. |

## P0 — freeze the display contract

- [x] Define the logical DMD surface permanently as 128×32.
- [x] Keep framebuffer width, framebuffer height, and DMD scale in board
      configuration.
- [x] Confirm `Landscape349` uses a 640×172 framebuffer, 5× scale, 640×160
      rendered DMD, and position `x=0`, `y=6`.
- [x] Add assertions that the rendered DMD surface never exceeds the configured
      framebuffer.
- [x] Verify `Waveshare7` remains unchanged at 800×480 with a 6× scale and a
      768×192 rendered DMD.
- [x] Prove both targets use the same rendering code and differ only through
      board/display configuration.

Evidence, 2026-08-12: `dmd_geometry.h` is the single logical/display geometry
contract used by the renderer and SCN validation. Compile-time assertions lock
both board layouts and reject framebuffer overflow. Clean ESP-IDF 5.5.2 QEMU
builds passed for `Landscape349` and `Waveshare7` from their separate sdkconfig
files.

**Pass condition:** both builds satisfy the shared 128×32 display contract with
no target-specific scene or rendering path.

## P1 — QEMU rendering validation

- [x] Build and run `Waveshare7` and `Landscape349` as separate QEMU models.
- [x] Validate `Landscape349` at exactly 640×172 in landscape orientation.
- [x] Verify clock and date rendering remains within screen bounds.
- [x] Verify static and animated SCN playback renders the full 128×32 scene.
- [x] Verify frames use one uniform 5× scale, retain the exact 4:1 aspect ratio,
      and occupy 640×160 pixels.
- [x] Verify the remaining 12 vertical pixels cause neither clipping nor writes
      outside the framebuffer.
- [x] Verify Basic, Gradient, Raster, Plasma, the renderer's black background,
      and brightness.
- [x] Verify scene transitions, random playback, and automatic scheduling.
- [x] Verify the QR/setup view and diagnostics remain bounded and usable.
- [x] Add framebuffer-boundary checks and representative screenshot or frame-hash
      evidence for both profiles.

Evidence, 2026-08-12: `Test-DmdClockQemuDisplay.ps1` captured and parsed binary
P6 framebuffers from both HMP monitors after normal rendering began. The final
post-refactor runs passed at exactly 640×172 and 800×480, each with 2,416 indexed
scenes, nonblank pixels inside the framebuffer, and SHA-256 evidence under
`output/esp32/reports/qemu-display`.

Acceptance evidence, 2026-08-13: `Test-DmdClockQemuAcceptance.ps1` captured 11
independent 640×172 P6 framebuffers for clock, static and animated SCNs,
Basic/Gradient/Raster/Plasma, 20/100 brightness, setup QR, and touch diagnostics.
It proved animated-frame progression, distinct theme/brightness/overlay hashes,
2,416-scene indexing, random automatic clock-to-scene transition, and active
current-hour schedule-off behavior. Evidence is under
`output/esp32/reports/qemu-acceptance/landscape349`.

**Pass condition:** representative clocks, static scenes, animated scenes, and
all color modes render correctly in `Landscape349` QEMU with no framebuffer
boundary errors.

## P2 — make UI geometry aware of the short display

The 640×172 display cannot reuse the Waveshare 7 touch-overlay geometry
unchanged.

- [x] Remove assumptions that top controls are always 46 pixels high.
- [x] Remove assumptions that bottom controls are always 56 pixels high.
- [x] Introduce board/layout-specific control geometry.
- [x] Keep the normal DMD view full-screen and unobstructed.
- [x] For `Landscape349`, use a temporary overlay or dedicated control screen
      instead of permanent chrome.
- [x] Ensure the full 640×160 DMD remains visible while controls are hidden.
- [x] Test every calculated button rectangle against framebuffer bounds.
- [x] Test simulated touch coordinates for every control zone in QEMU.

Evidence, 2026-08-12: `dmd_layout.h` keeps the Waveshare7 46/56-pixel geometry
and defines a compact 30/32-pixel, 4-pixel-margin `Landscape349` layout. Static
assertions bound every region. `dmd_controls_layout_self_test()` exercises all
eight actions during QEMU startup. Landscape chrome, including scene information,
is temporary; the final hidden-overlay capture contains only the 640×160 DMD.

**Pass condition:** `Landscape349` exposes every required control without
corrupting or permanently reducing the DMD scene area.

## P3 — separate panel hardware from DMD rendering

This is the architectural prerequisite for a maintainable second physical
target.

- [x] Refactor the physical display implementation so `dmd_display.c` does not
      directly assume the Waveshare 7 RGB panel.
- [x] Introduce a board/panel abstraction with separate Waveshare 7 and Waveshare
      3.49B backends, for example:

```text
dmd_display.c
      |
      v
dmd_panel.h
      |
      +-- dmd_panel_waveshare7.c
      +-- dmd_panel_waveshare349b.c
```

- [x] Give the common renderer only the panel operations it needs, such as
      `init`, `width`, `height`, `begin_frame`, `present_frame`, and
      `set_backlight`.
- [x] Move Waveshare 7 RGB GPIO and timing configuration out of generic rendering
      code.
- [x] Keep framebuffer management, DMD rendering, scene playback, clock,
      Plasma, and colorization common.
- [x] Keep the QEMU backend behind the same abstraction where practical.
- [x] Rebuild and regression-test `Waveshare7` after the refactor. Both its QEMU
      profile and physical ESP32-S3 firmware build pass on the final source.

Evidence, 2026-08-12: `dmd_panel.h` now fronts QEMU, Waveshare7, and a deliberately
blocked 3.49B physical backend. `dmd_display.c` has no panel GPIO, timing, or
`esp_lcd` calls. Both QEMU profiles passed build/runtime validation and the
Waveshare7 ESP32-S3 hardware target built successfully without flashing.

**Pass condition:** `dmd_display.c` contains no Waveshare 7-specific RGB GPIO
mapping, and Waveshare 7 still builds and behaves identically.

## P4 — identify the exact 3.49B hardware

Before implementing a physical driver, record and verify the exact board
revision from the official Waveshare schematic and matching vendor example.

- [x] Document the ESP32 module and both possible PCB revisions.
- [x] Document flash size.
- [x] Document PSRAM size and type.
- [x] Document the LCD controller and interface type.
- [x] Document LCD pins, reset sequence, and initialization command sequence.
- [x] Document LCD color format and maximum/recommended bus clock.
- [x] Document backlight GPIO and control behavior for both revisions.
- [x] Document touch controller, bus pins, interrupt pin, and reset behavior.
- [x] Document SD-card pins and bus mode.
- [x] Document the USB flashing and logging interface.
- [x] Record official factory images, source revisions, and integrity hashes.
- [x] Confirm the actual board's PCB silkscreen and enclosure QC sticker.
- [x] Recheck the matching factory-image hash immediately before recovery.
- [x] Prove the board can be restored to official factory firmware before
      flashing DMDClock.

Evidence (2026-08-12): the official V1 and V2 repositories, schematics, factory
examples, and recovery instructions were compared and recorded in
[`WAVESHARE-ESP32-S3-TOUCH-LCD-3.49B-HARDWARE.md`](WAVESHARE-ESP32-S3-TOUCH-LCD-3.49B-HARDWARE.md).
Waveshare identifies V2 by `Rev1.1` PCB silkscreen and a `V2` case sticker; V1
and V2 are not firmware-compatible. Physical revision identification and a
successful matching factory restore remain mandatory before P4 can pass.

Physical identification evidence (2026-08-13): the connected board was
confirmed as V2, and COM5 reported ESP32-S3 revision v0.2, 8 MB embedded PSRAM,
and 16 MB flash. The pinned official V2 image was rechecked at 2,813,008 bytes
with SHA-256
`1D1F84C766E720F344FAF59D1E6C95846DF1A26DA4C1E6D6094F9095F6B68312`.
Factory-recovery evidence (2026-08-13): the pinned official V2 image was written
to the physical board on COM5 and verified by the flasher. After reset, the
factory red/green/blue LCD cycle, touch canvas, SD-card capacity detection, and
SD-card read/write test all passed.

**Pass condition:** the exact hardware contract is documented and factory
recovery has been performed successfully on the physical board.

## P5 — minimal physical 3.49B display bring-up

Do not start physical qualification with DMDClock playback.

- [x] Create and build the standalone physical panel test and its automated
      flash/serial-evidence runner.
- [x] Initialize PSRAM and the panel, then turn on the backlight.
- [x] Display solid red, green, blue, black, and white frames.
- [x] Display a 640×172 coordinate/grid test pattern.
- [x] Verify landscape orientation and RGB/BGR byte/color order.
- [x] Verify there is no tearing or visible corruption.
- [x] Rerun the panel test continuously for at least 20 minutes with the corrected
      active-low GPIO42 backlight drive.

**Pass condition:** the physical 3.49B displays a stable, correctly oriented
640×172 framebuffer for at least 20 minutes.

Implementation (2026-08-13):
`firmware/diagnostics/waveshare349b-v2-panel-test` builds with the pinned
ESP-IDF 5.5.2 toolchain. `scripts/esp32/Test-DmdClockPhysical349B.ps1` validates
the V2 board contract, live ESP32-S3/8 MB PSRAM/16 MB flash, build artifacts and
hashes, then requires `FLASH`, monitors every color/grid stage, rejects crash
markers, and writes JSON plus serial-log evidence. Its COM5 `-WhatIf` path
passed. The initial 60-minute runner completed 188 transfers with every stage
present, unchanged free heap, and no detected crash, but later cold-start
observation exposed that GPIO42 had been driven high even though the V2
backlight PWM is active low. That run therefore proves transfer stability, not
an illuminated one-hour soak. After correcting GPIO42 to low, a repeat physical
run visibly cycled the correctly oriented red, green, blue, black, white, and
grid stages without corruption. Evidence for the corrected visual run is at
`output/esp32/reports/physical-349b/panel349-v2-20260813T214535Z.json`; its
The corrected illuminated repeat completed 62 full color/grid cycles in 20.002
minutes with every required stage present and no detected fatal output. Evidence
is at `output/esp32/reports/physical-349b/panel349-v2-20260813T223854Z.json`.

## P6 — connect the physical panel to the shared DMD renderer

- [x] Connect the 3.49B panel backend to the shared `dmd_display` layer.
- [ ] Render a synthetic 128×32 DMD test pattern at exactly 5×.
- [x] Verify physical output is 640×160 at `x=0`, with 6 pixels above and below.
- [x] Render and visually verify the clock and a static SCN.
- [x] Render an animated SCN at the correct visual cadence on the physical
      3.49B and compare it directly with the Waveshare 7.
- [x] Test Basic, Gradient, Raster, and Plasma modes.
- [x] Reduce physical full-frame presentation below the 100 ms timing of the
      observed SCN animation so transfer work no longer consumes an entire
      animation frame interval.
- [x] Verify that enabling `Scene information` from the web UI makes the
      metadata row visibly appear on the physical `Landscape349` display even
      after the temporary control overlay has faded; it must not be silently
      gated by an expired touch-overlay timer.
- [ ] Compare representative physical scenes with `Landscape349` QEMU evidence.

**Pass condition:** physical output matches the `Landscape349` model closely
enough that remaining differences are attributable only to the LCD hardware.

Implementation evidence (2026-08-13): the production 3.49B backend uses
the physically proven V2 AXS15231B QSPI initialization, TCA9554 reset/backlight
control, chunked DMA transfer, RGB565 byte order, and native-to-landscape
rotation. Storage uses the board's GPIO39/40/41 1-bit SDMMC path. The isolated
`Waveshare349B` build verifies 640×172 geometry and 5× scale before accepting an
artifact. The development image was flashed to the V2 board on COM5, mounted
the physical TF card, indexed all 2,416 scenes, initialized the 640×172 panel,
reached the web-ready state, and advanced between scenes during a clean one-minute
serial capture. A task-watchdog warning found on the first attempt was traced to
the full metadata scan; periodic scheduler yields fixed it, and the physical
runner now rejects watchdog output. Evidence is at
`output/esp32/reports/physical-349b-app/dmdclock349-v2-20260813T214756Z.json`.
A black-screen visual failure then exposed the same incorrect GPIO42 polarity
in the production backend. Official V2 factory recovery displayed correctly,
the active-low correction made the standalone color/grid test visible from a
cold start, and the corrected DMDClock image then rendered visibly with the
expected landscape orientation, colors, full-width 5× DMD, equal six-pixel
margins, and no observed tearing or corruption. The post-fix 11-case
`Landscape349` QEMU matrix also passes. Physical clock/static/animated coverage,
all four color modes, and direct representative comparison with the QEMU
captures remain open.

Performance evidence (2026-08-14 local time): instrumentation initially measured
about 96-121 ms for each physical 640x172 presentation. Matching the official
64-row DMA stripe size reduced transaction count but not elapsed time. Reordering
the native-to-landscape rotation to read the PSRAM framebuffer contiguously
reduced stable presentation time to about 35.6 ms while preserving the same
pixel mapping. The rebuilt image was flashed to COM5 and completed a clean
one-minute serial run with all required markers and no fatal output. Evidence is
at `output/esp32/reports/physical-349b-app/dmdclock349-v2-20260813T220053Z.json`.

Animation acceptance (2026-08-14): ten shared scene indices were sent through
the local APIs to the physical 3.49B and Waveshare 7. Both devices accepted all
ten selections. Active `sceneFrame` sampling showed a stable offset rather than
accumulating drift; starting the Waveshare 7 about 450 ms first aligned the two
devices within zero or one reported frame. Direct observation then confirmed
that the displays remained visually synchronized. Evidence is at
`output/esp32/reports/physical-349b-app/dual-device-scene-rate-20260814.json`.

Physical visual acceptance (2026-08-14): the clock, a single-frame
`APOLLO_13_001.scn`, and representative Basic, Gradient, Raster, and Plasma
settings were applied through the local API to both the 3.49B and Waveshare 7.
Direct observation confirmed the clock, static scene, and all four color
families render correctly on the 3.49B.

Web information acceptance (2026-08-14): changing `showInformation` now resets
the temporary overlay timer in the display task. Both physical targets build,
and the corrected 3.49B image passed a clean one-minute COM5 smoke test at
`output/esp32/reports/physical-349b-app/dmdclock349-v2-20260813T222648Z.json`.
After the overlay had fully faded, the web API toggled scene information off and
back on for `APOLLO_13_001.scn`. Direct observation confirmed that the metadata
row appeared immediately with correct text and placement, then faded after
about eight seconds.

Final P6 candidate evidence (2026-08-14): temporary presentation-timing logs
were removed while retaining the accepted 64-row DMA transfer and cache-friendly
rotation. The credential-free image builds for both physical targets. The
3.49B application image is 1,308,368 bytes with SHA-256
`72D45B536C96B9765CEEE7875E2F35D1BEEC65EF91A79F81774851AE0981C5F6` and
passed its final one-minute COM5 smoke test at
`output/esp32/reports/physical-349b-app/dmdclock349-v2-20260813T223429Z.json`.

## Preview release gate

The first GitHub preview must remain an explicit prerelease for **3.49B V2 /
Rev1.1 only**. Physical touch is qualified for that exact revision. The preview
requires:

- [x] P5 illuminated 20-minute panel soak passes.
- [ ] P6 physical renderer acceptance passes, with any remaining comparison
      limitation stated in the release notes.
- [ ] A credential-free V2-specific package, manifest, and SHA-256 list pass
      download and flash verification.
- [ ] Official V2 factory recovery remains documented and independently
      available.

P8-P9 below remain the backlog for stable first-class support.

## P7 — physical touch bring-up — complete

Treat touch as a separate hardware qualification.

- [x] Record the current P6 baseline: touching the physical display produces no
      visible response because touch is deliberately disabled in the P6 image;
      this does not qualify the controller or prove a hardware failure.
- [x] Detect the touch controller and log raw X/Y coordinates.
- [x] Determine that the controller reports a 640×172 raw coordinate range for
      the portrait-native panel mounting.
- [x] Rotate native touch input into 640×172 landscape coordinates and verify
      the corrected horizontal mapping physically.
- [x] Verify all four corners and the center with a five-point touch test.
- [x] Verify neither axis is mirrored or inverted.
- [x] Verify touch remains correct after display rotation.
- [x] Connect touch to the `Landscape349` overlay/control layout.

**Pass condition:** five-point diagnostics succeed and every visible control
activates the intended action.

Physical button-map capture on 2026-08-14 first detected a reversed horizontal
order and led to removal of an extra `639 - raw_x` inversion. The corrected
capture then verified neutral menu reveal, `NEXT PINBALL` at `95,30` changing
scene 180 to 183, `NEXT SCENE` at `341,6` changing scene 183 to 184, `RANDOM`,
and all five lower controls from left to right with the intended state changes
and zero I2C errors. Evidence is stored in
`output/esp32/reports/physical-349b-touch/button-map-corrected.json` and
`button-map-top-corrected.json`.

## P8 — regression-test both physical targets (stable-release backlog)

Run the same acceptance matrix on both boards after 3.49B support works.

### Waveshare 7

- [ ] Boot.
- [ ] SD mount.
- [ ] Wi-Fi.
- [ ] NTP.
- [ ] Clock.
- [ ] SCN playback.
- [ ] Plasma/themes.
- [ ] Touch.
- [ ] Web interface.

### Waveshare 3.49B

- [ ] Boot.
- [ ] Storage.
- [ ] Wi-Fi.
- [ ] NTP.
- [ ] Clock.
- [ ] SCN playback.
- [ ] Plasma/themes.
- [ ] Touch.
- [ ] Web interface.

**Pass condition:** adding `Landscape349` causes no functional regression on
Waveshare 7, and both boards pass their complete physical matrix.

## P9 — stable packaging

- [ ] Build separate firmware artifacts from the same source tree.
- [ ] Use stable target IDs such as `waveshare7-n16r8-800x480` and
      `waveshare-esp32-s3-touch-lcd-3-49b-v2-640x172-n16r8`.
- [ ] Package separate firmware binaries and board metadata.
- [ ] Prevent a Waveshare 7 image from being flashed onto a 3.49B and vice versa.
- [ ] Print the selected board target prominently before flashing.
- [ ] Package the correct partition table and bootloader for each target.
- [ ] Document USB flashing and recovery separately for each board.
- [ ] Validate release manifests, checksums, embedded board identity, and a
      live-downloaded package for each target.

**Pass condition:** one source tree produces two independently installable and
recoverable firmware targets that play the same SCN library and use the same
DMDClock application logic.

## Final acceptance

- [ ] Waveshare 7 remains supported at 800×480 with a 128×32 DMD rendered at 6×.
- [ ] Waveshare 3.49B is supported at 640×172 landscape with a 128×32 DMD rendered
      at 5×.
- [ ] Both targets use the same scenes, metadata, settings, web API, playback,
      clock, colorization, and Plasma logic.
- [ ] `Landscape349` QEMU passes before every physical 3.49B firmware candidate is
      flashed.
- [ ] Both physical boards pass regression and soak testing with recoverable,
      board-specific release packages.
