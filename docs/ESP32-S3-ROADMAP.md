# DMDClock ESP32-S3 roadmap

Project repository:
[DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32).

ESP32 work is developed on dedicated feature branches and merged only after the
production and QEMU profiles build and the connected board passes the relevant
live checks.

This roadmap defines a separate embedded product for the
**Waveshare ESP32-S3-Touch-LCD-7** while keeping the Windows application as the
reference implementation. The first hardware target is the original 800×480 RGB
model with an ESP32-S3-WROOM-1-N16R8 module, 8 MB PSRAM, capacitive touch, and an
onboard TF-card slot. The 1024×600 `7B` is a different target and must use a
different board identifier and display configuration.

The embedded firmware is not a build of the Avalonia application. It is an
ESP-IDF C/C++ implementation that consumes the same generated color data, format
fixtures, and behavioral test vectors as the .NET implementation.

## Goals

- Render the classic 128×32 four-bit DMD on the internal 800×480 display.
- Support clock, date, DotClk bitmap fonts, `.scn` playback, automatic cycles,
  scene selection, and the same Basic, Plasma, Gradient, and Raster choices as
  Windows.
- Use touch for an overlay menu without permanently occupying display space.
- Store scenes and library data on the onboard TF card.
- Synchronize time over Wi-Fi while preserving a useful clock during temporary
  network or NTP loss.
- Support local USB flashing, serial diagnostics, OTA updates, rollback, and a
  recoverable factory image.
- Build, test, package, flash, and monitor on the developer's local Windows
  workstation. ChatGPT may edit source and run the local scripts, but compilation
  must not depend on a hosted build service or an active AI subscription.

## Non-goals for the first firmware release

- Running .NET or Avalonia on the ESP32-S3.
- OpenType/TTF rendering.
- The full desktop Scene Reviewer on the device.
- Windows installer, screensaver, window-management, or file-picker behavior.
- Supporting the Waveshare 7B, other LCD timings, or external physical DMDs from
  the first board package.
- Bundling resources whose redistribution rights have not been confirmed.

## Build-readiness audit

This is the current repository, workstation, and connected-hardware state as
verified on 2026-07-30. It is the starting point for the ordered plan below.

Live hardware update, 2026-07-30:

- The connected Waveshare 800×480 N16R8 board is available as
  `DMDClock-59D9` and flashes on COM4.
- Production firmware scans `/dmd/scenes` instead of using the former
  11-filename allowlist; the live 64 GB card exposes all 2,324 SCNs.
- The touch overlay uses wide `Next pinball` and `Next scene` controls plus
  colour-family, next-theme, information, glow, and NTP controls.
- NTP shows successful-check age on-device and exact last-sync time plus age in
  the web remote.
- Optional 256 KB rotated playback logging records scene and theme events under
  `/dmd/logs`.
- Web-editable settings are mirrored to `/dmd/config/settings.json`, and the
  embedded `/api-docs` page describes all current local HTTP calls.
- The web remote shows effective screen state and provides a confirmed reboot
  action; both were verified against the live device.

| Area | Current state | Required fix |
|---|---|---|
| Windows reference | Plasma and the versioned release pipeline are merged into `master`; the expanded color controls build locally | Preserve this baseline through every shared-data migration |
| Working branch | ESP32 work is published on dedicated feature branches | Keep each branch scoped and require production, QEMU, and relevant live checks before merge |
| Theme definitions | Repeated across settings, renderer, menu labels, swatches, and localization | Move stable IDs and RGB/band data into canonical shared definitions |
| Plasma | Windows and ESP32 use the frozen integer field, eight palettes plus Custom, and startup vectors | Add cross-platform palette and framebuffer hash tests |
| ESP32 firmware | Production ESP-IDF firmware is running on the exact board with SD scenes, NTP, touch controls, diagnostics, and web/API control | Complete extended soak, flicker measurement, recovery, and security work |
| Shared inputs | No `shared` directory | Add schema-validated canonical definitions and deterministic generation |
| ESP32 scripts | Doctor, vendor-example build, production/QEMU build, QEMU run, explicit-port flash, and idempotent SD preparation work | Add packaging and repeatable hardware-test automation |
| Build automation | No `.github/workflows` directory | Keep local builds primary; add independent verification only after local firmware is reproducible |
| Local .NET | Workspace-local .NET 10 is working | Reuse it for the shared generator and Windows contract tests |
| Local firmware tools | Pinned ESP-IDF 5.5.2 toolchain is installed and a full ESP32-S3 build passes | Keep Arduino and PlatformIO out of the primary pipeline |
| Connected board | Waveshare board is connected as COM4 and runs as `DMDClock-59D9` | Keep explicit-port flashing and never infer a destructive target |
| Exact board revision | Original 800×480 `ESP32-S3-Touch-LCD-7` with N16R8 module is confirmed | Keep the 1024×600 7B as a separate unsupported target |
| Recovery | Official package and its `Firmware/*.bin` recovery images are archived under ignored `external/` | Identify the correct factory image and test its documented `0x00` restore before custom flashing |
| TF card | A 64 GB FAT32 card mounts and exposes all 2,324 prepared scenes plus metadata and settings | Test removal, corruption, full-card, and power-loss behavior |
| Scene redistribution | Original scenes have redistribution caveats | Keep them out of public firmware/card images; let users obtain them from their original source |
| OTA/recovery | Not designed or tested | Defer OTA until USB recovery and a stable partition table work |

## Required resources

### Hardware on the desk

- [x] Waveshare `ESP32-S3-Touch-LCD-7`, physically confirmed as 800×480.
- [x] Module confirmed as `ESP32-S3-WROOM-1-N16R8`.
- [x] Data-capable USB cable connected to the port labeled `UART` for initial
      flashing and serial logs.
- [ ] A second data-capable cable for native USB/JTAG testing if the board exposes
      both connectors.
- [x] Stable 5 V USB power.
- [x] Reliable TF/microSD card prepared as FAT32.
- [x] A local folder containing the vendor schematic, current example source,
      factory binary, and recovery notes.

### Software on the workstation

- [x] Git.
- [x] Workspace-local .NET 10 for Windows tests and code generation.
- [x] Sufficient CPU and RAM for local parallel builds.
- [x] Pinned ESP-IDF 5.5.2 checkout and tools beneath
      `E:\ai\.tools\esp-idf`.
- [x] ESP-IDF-managed Python environment.
- [x] ESP-IDF-compatible CMake, Ninja, Xtensa compiler, and esptool.
- [x] Current official Waveshare example archive saved locally with SHA-256
      `5351D443EAA605CAB1EB80D050D867C18E1CE2B33C9CBC78AAE1B7BCA040B038`.
- [ ] A serial terminal path verified by `Doctor.ps1`.

Do not install several competing toolchains initially. Bring up the official board
example with one pinned ESP-IDF environment first. Arduino or PlatformIO can be
evaluated later, but they are not required for the primary firmware pipeline.

## Remaining safety and shared-data work

### P0 — repository and recovery safety

- [x] Stabilize the Windows colour/menu baseline.
- [x] Keep ESP32 work on scoped feature branches.
- [x] Confirm the exact physical board and module revision.
- [x] Archive the vendor factory image.
- [ ] Test the complete factory-image restore procedure.
- [x] Record the USB connector, driver, COM port, flash command, and reset/
      boot-button sequence.

Current development flashing uses an explicit COM port and does not erase NVS
unless an erase operation is requested. Factory restore must be proven before
OTA work or a firmware release is considered complete.

### P0 — eliminate remaining cross-platform colour drift

The current color implementation contains multiple handwritten representations:

- enum IDs and Plasma stops in `DmdClockSettings.cs`;
- dot, Gradient, and Raster RGB data in `DmdDisplay.cs`;
- visual menu swatches and background defaults in `MainWindow.axaml.cs`;
- display names in localization JSON.

Firmware currently mirrors the stable Windows IDs. Before the first firmware
release, replace those parallel handwritten definitions with:

1. Define stable IDs and color data once under `shared/dmd`.
2. Generate the C# runtime tables and C++ firmware tables.
3. Keep translated names outside the generated numeric/color data.
4. Make both builds run generator check mode.
5. Make tests compare generated theme counts, IDs, RGB values, band order, Plasma
   output, and representative framebuffer hashes.

This is the key fix that guarantees a Windows Plasma or color change also updates
the ESP32 build.

### P1 — define embedded compatibility contracts

- Freeze the packed 128×32 four-bit frame representation.
- Define SCN parsing limits suitable for streaming from TF card.
- Publish versioned settings IDs rather than relying on C# record layout.
- Define the theme/background behavior in platform-neutral tests.
- Convert approved bitmap fonts through a generator; do not hand-copy them.
- Define monotonic timing tolerance for Windows versus FreeRTOS.

### P1 — separate build from hardware mutation

- `Generate`, `Test`, `Build`, and `Package` may run unattended locally.
- `Flash`, `Erase`, partition-table replacement, and OTA installation require an
  explicit board/port target.
- An ordinary build must never erase or reset a connected device.
- Flash scripts print target ID, COM port, binary hashes, and partition version
  before writing.

## Strict implementation order

Each gate depends on the previous gate. Do not work around a failed gate by adding
application features.

### Gate 0 — clean reference baseline

Actions:

- Review current Windows changes.
- Run Debug and Release tests.
- Commit the known-good Plasma/color work.
- Create the dedicated ESP32 feature branch.

Pass condition: clean worktree, recorded commit, and all Windows tests green.

### Gate 1 — identify and recover the board

Actions:

- Photograph board and module markings.
- Connect the UART USB port and identify its COM device.
- Save the official schematic, examples, and factory binary.
- Erase, restore, and boot the factory image once.

Pass condition: one documented command can restore a black-screen or invalid
firmware situation.

### Gate 2 — pinned local toolchain

Actions:

- Read the vendor example metadata to determine its compatible ESP-IDF release.
- Pin that ESP-IDF commit and component lock.
- Implement `Install-Toolchain.ps1` and `Doctor.ps1`.
- Install tools beneath `E:\ai\.tools`, not system-wide.
- Record tool versions in `output/esp32/reports/toolchain.json`.

Pass condition: `Doctor.ps1` reports every dependency and the connected board
without relying on an interactive ESP-IDF shell.

### Gate 3 — untouched vendor examples

Actions:

- Build the vendor color-bar example locally.
- Flash it and verify RGB timing/backlight.
- Build and run the touch example.
- Build and run the TF-card example.
- Save the working `sdkconfig`, pin mapping, and dependency versions.

Pass condition: display, touch, PSRAM, TF card, serial logging, and reset work before
any DMDClock source is introduced.

### Gate 4 — shared source generation

Actions:

- Add the canonical theme and Plasma files.
- Extend `DmdClock.Tools` with deterministic C# and C++ generation.
- Migrate Windows away from handwritten RGB/band tables.
- Add stale-generation checks and cross-platform fixtures.

Pass condition: one edit to a canonical palette changes generated C# and C++; both
builds reject stale output.

### Gate 5 — minimal DMD firmware

Actions:

- Scaffold the ESP-IDF application from the verified board configuration.
- Allocate the RGB565 framebuffer safely.
- Render one synthetic packed 128×32 frame at centered 6× scale.
- Add serial boot diagnostics and a watchdog-safe display loop.

Pass condition: the board displays a stable test pattern for one hour without
tearing, reset, allocation failure, or temperature/power instability.

### Gate 6 — basic interface and fixed colors

Actions:

- Consume the generated C++ Basic color definitions.
- Implement only fixed Basic colors, explicit background behavior, and brightness.
- Add the smallest usable touch interface for selecting those values.
- Run shared fixed-color lookup and framebuffer hash vectors.
- Measure frame time, CPU load, heap, and PSRAM use.

Pass condition: fixed colors, touch, and persisted settings remain responsive and
stable through a one-hour test. Plasma, Gradient, and Raster are explicitly
excluded from this gate.

### Gate 7 — clock-first usable firmware

Actions:

- Add approved bitmap fonts.
- Add clock/date layout, Wi-Fi provisioning, timezone, configurable SNTP, and NVS
  settings.
- Add a minimal touch overlay for color, brightness, time, and date.

Pass condition: after power loss the board reconnects, restores settings, and shows
a correct clock without a development PC.

### Gate 8 — TF-card SCN playback

Actions:

- Port the bounds-checked streaming SCN reader.
- Reuse the compatibility and malformed-file corpus.
- Add scene indexing, playback timing, selection, and automatic cycles.
- Test card removal, corrupt files, and rebuildable caches.

Pass condition: agreed scenes match Windows frame/timing fixtures and storage
failures do not stop the clock.

### Gate 9 — complete touch/web controls

Actions:

- Add transient touch controls and the complete settings hierarchy.
- Add a lightweight local web UI using the same stable settings IDs.
- Require first-run administrator setup before exposing normal web controls.
- Add an NTP settings page with enable/disable, primary and secondary server,
  timezone, bounded synchronization interval, `Sync now`, last-success time,
  current offset, and clear error/status reporting.
- Add device-side HTTPS SCN downloads to the TF card with progress and atomic
  installation.
- Add authenticated live and downloadable logs with bounded rotation and secret
  redaction.
- Add an authenticated live Statistics page covering chip temperature, CPU,
  memory, rendering, storage, network, time, web/MQTT, and OTA state.
- Keep HTTP, touch, and storage work isolated from display refresh.

Pass condition: all daily configuration and scene choices work without reflashing.

### Gate 9a — Home Assistant integration

Actions:

- Add optional MQTT broker settings and Home Assistant MQTT device discovery.
- Publish availability, clock/display state, diagnostics, and current playback
  state without making rendering dependent on the broker.
- Expose safe controls for display power, brightness, fixed color, operating mode,
  scene navigation, and temporary text notifications.
- Test broker loss, reconnect, retained discovery, command validation, and restart.

Pass condition: Home Assistant discovers one DMDClock device with useful controls
and diagnostics, while the clock remains fully functional with MQTT disabled or
offline.

### Gate 9b — advanced visual effects

Actions:

- Add Gradient and Raster from generated shared definitions.
- Add Plasma only after fixed-color rendering, clock, SCN playback, web controls,
  logging, and CPU instrumentation are stable.
- Add the optional **Hot-core glow** dot style with a bright centre and soft
  colour-matched halo. Preserve clear separation between adjacent dots and keep
  the existing lightweight glow as the fallback.
- Run shared lookup/framebuffer vectors and measure per-effect CPU load, frame
  time, PSRAM bandwidth, dropped frames, and control responsiveness.
- Retain an automatic fixed-color fallback if an advanced effect cannot sustain
  the agreed frame budget.

Pass condition: each advanced effect meets its shared parity and performance
budgets without weakening the stable fixed-color mode.

### Gate 10 — recovery-grade updates and packages

Actions:

- Freeze the partition table.
- Add application-only OTA A/B validation and rollback.
- Produce first-flash, OTA, manifest, checksum, and TF-card artifacts.
- Run clean-flash, interrupted-update, rollback, and USB-recovery tests.

Pass condition: the release definition of done at the end of this document is met.

## Immediate next visual feature — Hot-core glow

After the owner completes the v1.3.0 manual Windows release checklist, Hot-core
glow is the next visual feature for both Windows and ESP32-S3.

Visual construction:

1. Use a warm yellow-white core about 22–28% of the dot diameter. Avoid pure
   white so the selected theme colour remains visible.
2. Surround it with the saturated selected colour, then a soft colour-matched
   halo that fades out before the midpoint between neighbouring dot centres.
3. Scale the core and halo with the source's 0–15 intensity. Dim pixels must stay
   dim instead of gaining the same bright centre as a fully lit pixel.
4. Let glow strength control the core and halo together, with zero returning the
   existing clean dot rendering.

Implementation plan:

- Windows caches radial-gradient brushes by theme, intensity, scale, and strength.
- ESP32-S3 uses a precomputed three-ring kernel or small lookup table and avoids
  per-pixel square roots. The existing lightweight glow remains the fallback.
- Shared setting names and reference frames define visual intent without requiring
  pixel-identical rasterization on the two different renderers.
- The worst-case all-dots frame must retain a black saddle between every pair of
  dots. Plasma and SCN playback must keep the 30 FPS budget while touch and web
  controls remain responsive.
- Record frame time, CPU load, PSRAM bandwidth, and dropped frames before enabling
  the effect by default or raising its maximum strength.

## Fixed target identity

Use a target identifier everywhere a binary, manifest, settings document, or OTA
request is handled:

```text
waveshare-esp32-s3-touch-lcd-7-800x480-n16r8
```

Firmware must refuse an OTA package for a different target. A future 7B port gets
its own identifier, partition table, board configuration, and artifacts.

## One source of truth for shared behavior

Manually maintaining the same palettes in C# and C++ is not acceptable. Shared
definitions are canonical inputs, and both platform representations are generated.

```text
shared/dmd/
├─ themes.json
├─ plasma.json
├─ settings-schema.json
├─ fonts/
└─ test-vectors/
   ├─ plasma/
   ├─ palettes/
   ├─ frames/
   └─ scn/
          │
          ▼
tools/DmdClock.Tools generate-shared
          │
          ├─► src/DmdClock.Core/Generated/*.g.cs
          ├─► firmware/waveshare-esp32-s3-7/main/generated/*.hpp
          └─► shared/dmd/generated-manifest.json
```

The generator must be deterministic. Windows and ESP32 builds run it in check
mode and fail when committed generated files do not match the canonical inputs.
Changing a Plasma palette, Basic color, Gradient, Raster sequence, default
background, speed preset, or persisted setting therefore updates both products in
the same change.

### Shared data rules

- Theme IDs are stable integers and are never renumbered.
- Existing Windows settings enum values remain compatible.
- Colors use uppercase `#RRGGBB`.
- Raster definitions store the complete ordered band list.
- Plasma definitions store four color stops and integer timing values.
- Generated C# and C++ expose the same IDs, names, RGB values, and defaults.
- Translated display names remain in platform localization files; stable theme IDs
  never depend on translated text.
- A manifest records input hashes, generator version, and generated-output hashes.

### Shared algorithm rules

Algorithms that cannot reasonably share source language use a shared contract:

- one written integer algorithm specification;
- fixed lookup tables generated from one source;
- identical input/output test vectors;
- exhaustive range tests where practical;
- framebuffer hashes for integration tests.

The Plasma sine table, phase calculation, 128-color interpolation, and reference
coordinates are the first contract. The existing Windows vectors remain the
baseline. No ESP32-specific approximation may silently replace them.

Longer term, evaluate a small portable C core for frame composition and SCN
decoding. Do not block the first firmware on that refactor; dual implementations
with shared fixtures are acceptable while their output remains byte-identical.

## Proposed repository layout

```text
DMD-Pinball-Clock-Win-x64-and-ESP32/
├─ src/
├─ tests/
├─ tools/
│  └─ DmdClock.Tools/
├─ shared/
│  └─ dmd/
├─ firmware/
│  └─ waveshare-esp32-s3-7/
│     ├─ main/
│     │  ├─ generated/
│     │  ├─ board/
│     │  ├─ display/
│     │  ├─ playback/
│     │  ├─ rendering/
│     │  ├─ settings/
│     │  ├─ storage/
│     │  ├─ touch/
│     │  └─ network/
│     ├─ test/
│     ├─ assets/
│     ├─ CMakeLists.txt
│     ├─ dependencies.lock
│     ├─ idf_component.yml
│     ├─ partitions.csv
│     ├─ sdkconfig.defaults
│     └─ README.md
├─ scripts/
│  └─ esp32/
│     ├─ Install-Toolchain.ps1
│     ├─ Doctor.ps1
│     ├─ Generate-Shared.ps1
│     ├─ Test-Firmware.ps1
│     ├─ Build-DmdClock.ps1
│     ├─ Install-DmdClockEsp32.ps1
│     └─ Package-DmdClockEsp32.ps1
└─ output/
   └─ esp32/
```

All firmware build output stays under the already ignored `output` directory.
Tool downloads stay under `E:\ai\.tools` and must not be committed.

## Local workstation and toolchain

The current workstation inventory recorded and verified on 2026-07-27 is:

- MSI MPG Z690 Infinite X2;
- Intel Core i7-13700KF;
- 16 physical cores / 24 logical processors;
- 63.8 GB usable RAM;
- local Git;
- local .NET 10 SDK under `E:\ai\.tools\dotnet10`;
- EIM 0.17.1 under `E:\ai\.tools\eim\v0.17.1`;
- ESP-IDF 5.5.2 at commit
  `30aaf64524299d3bde422ca9a2848090d1bc5d0f`;
- managed Python 3.14.4, CMake 3.30.2, Ninja 1.12.1, Xtensa GCC 14.2.0,
  and esptool 4.12.0 under `E:\ai\.tools\esp-idf\v5.5.2`;
- no Arduino CLI or PlatformIO, by design.

This is ample capacity for parallel ESP-IDF and .NET builds. Local scripts should
default to 20 build jobs, leaving four logical processors available for the
desktop and serial tooling. Every build script must accept `-Jobs` to override
that choice.

Both an official ESP-IDF `hello_world` project and the untouched Waveshare
`08_lvgl_Porting` project compile successfully for ESP32-S3. The latter produced
a 655,616-byte application image using the board's 8 MB flash configuration.
`Doctor.ps1` writes the repeatable inventory to
`output/esp32/reports/toolchain.json`.

### Toolchain policy

- Pin one supported ESP-IDF release for reproducible firmware builds.
- Install ESP-IDF and its managed Python environment beneath
  `E:\ai\.tools\esp-idf`; do not rely on global PATH state.
- Let ESP-IDF install its compatible Python, CMake, Ninja, compiler, and esptool
  versions. The system Python 3.14 is not assumed compatible with ESP-IDF.
- Record the ESP-IDF commit and component lock file.
- `Doctor.ps1` reports exact paths and versions without modifying the machine.
- `Install-Toolchain.ps1` explains downloads and disk usage, supports a dry run,
  and never deletes or replaces an unrelated ESP-IDF installation.
- Build scripts import the pinned ESP-IDF environment internally.
- Network access is needed only for explicit tool/component installation and
  dependency updates, not for normal builds.

## Local developer commands

The intended entry points are:

```powershell
# Verify local prerequisites and discover the connected board.
.\scripts\esp32\Doctor.ps1

# Rebuild the cached untouched display/touch example without a board.
.\scripts\esp32\Build-WaveshareExample.ps1 -Example LVGL

# Build the cached TF-card example.
.\scripts\esp32\Build-WaveshareExample.ps1 -Example SD

# Run another idf.py command against an explicit project.
.\scripts\esp32\Invoke-Idf.ps1 -ProjectPath <path> build

# Regenerate C# and C++ from the canonical shared definitions.
.\scripts\esp32\Generate-Shared.ps1

# Test shared generation, native firmware logic, and the .NET reference.
.\scripts\esp32\Test-Firmware.ps1 -Jobs 20

# Compile locally for the fixed Waveshare target.
.\scripts\esp32\Build-DmdClock.ps1

# Download a release and optionally flash, or flash the current local build.
.\scripts\esp32\Install-DmdClockEsp32.ps1
.\scripts\esp32\Install-DmdClockEsp32.ps1 -LocalBuild -Port COM5 -Monitor

# Produce the USB install/update ZIP, manifest, and checksum artifacts.
.\scripts\esp32\Package-DmdClockEsp32.ps1
```

Build and test scripts may be run automatically by an agent because they only
change ignored build output. Flashing, erasing, partition changes, OTA deployment,
and hardware reset are explicit commands because they mutate the connected board.

## Display and memory design

Render a centered 768×192 DMD surface using exact 6× scaling:

```text
128 × 6 = 768
 32 × 6 = 192
```

The 800×480 screen leaves 16 pixels at each side and 144 pixels above and below.
Normal playback keeps the unused area dark. Touch controls and status information
temporarily overlay that space.

An 800×480 RGB565 framebuffer uses 768,000 bytes. Two full buffers use about
1.54 MB and fit in 8 MB PSRAM. DMA constraints and RGB-panel bandwidth must be
measured on hardware; allocation success alone is not sufficient.

The display task must not block on TF-card reads, Wi-Fi, JSON parsing, or scene
scanning. Frame decoding and display refresh use separate FreeRTOS tasks and a
bounded frame queue.

## Firmware architecture

```text
Wi-Fi + SNTP ───────┐
Touch + web UI ─────┼─► settings/scheduler
NVS settings ───────┘          │
                               ▼
TF card ─► SCN reader ─► 4-bit DmdFrame
                               │
Clock/date ────────────────────┤
                               ▼
                 theme/plasma compositor
                               │
                               ▼
                    RGB565 display task
```

- Internal flash: firmware, OTA slots, recovery metadata, minimal recovery web
  assets, one fallback bitmap font, and NVS. Production embeds no SCN files.
- TF card: a single `/dmd` root containing scenes, optional converted font
  packs, Plasma assets, extended web assets, exported configuration, backups,
  bounded logs, rebuildable indexes/caches, downloaded manifests, temporary
  download files, and rollback-safe content snapshots.
- Wi-Fi: configurable SNTP, local web settings, optional scene/package download,
  and application OTA.
- Touch: transient playback controls and settings overlay.

## Settings ownership

The browser does not own or host the settings. The web UI is served by the ESP32
and calls its local settings API. Versioned settings are persisted in NVS, while
larger rebuildable data such as the scene index and playlists may live on the TF
card. Closing the browser, losing Wi-Fi, or replacing the card must not reset the
clock's core configuration.

NTP settings persisted in NVS are:

- NTP enabled;
- primary server hostname;
- optional secondary server hostname;
- bounded synchronization interval;
- timezone and daylight-saving rule;
- use DHCP-provided NTP servers when available.

The web page also exposes read-only synchronization state: current clock source,
last attempt, last successful sync, measured offset, and the most recent error.
`Sync now` triggers an asynchronous request and must never block display refresh.
The clock continues from its local timebase during a network or NTP outage and
resynchronizes when connectivity returns.

## Web authentication

The current implemented release boundary is deliberately smaller:

- [x] Default to LAN-only HTTP access and enforce it at socket acceptance so the
      remote, API documentation, and every API route share the same boundary.
- [x] Persist the LAN-only switch in NVS and the editable SD settings backup.
- [x] State clearly that the filter is not authentication: private-LAN clients
      remain trusted and HTTP traffic is unencrypted.

The authenticated design below is optional future hardening, not current
firmware behavior.

The web interface uses `admin` as the initial username, but the firmware must not
ship with a shared `admin/admin` credential. On first run, the local display shows
a temporary per-device setup code. The first browser session uses that code to
open a minimal password-creation page, and all other web routes remain locked
until a new administrator password is confirmed.

Only a salted password verifier is stored in NVS; plaintext passwords, temporary
codes, and active session tokens are never logged. Authenticated sessions use
random, expiring tokens and CSRF protection. Repeated failures are rate-limited.
A forgotten password is reset only through a documented physical-button sequence
or local USB recovery, not through an unauthenticated network endpoint. Resetting
web access must not erase SCN files or unrelated clock settings.

## Device-side SCN acquisition

The web interface asks the ESP32 to download selected SCN files itself. The
browser may disconnect after starting a job; the device owns the transfer and
reports its status when the user reconnects.

The library page also provides **Download complete DotClk scene set**, matching
the Windows application's user-visible action. It obtains the scenes from the
original `sigmafx/DotClk-Resources` source and stores them on the TF card; the
firmware image and public release packages do not redistribute the scenes.

Each download must:

1. use HTTPS and reject unsupported URL schemes;
2. sanitize the destination filename and prevent path traversal;
3. check TF-card presence, free space, and a configured maximum file size;
4. write to a temporary file while reporting progress and allowing cancellation;
5. verify the SCN header, bounds, and optional catalog SHA-256;
6. atomically rename a valid file and trigger an incremental library rescan;
7. remove incomplete temporary data after failure or restart.

A source-configurable catalog can expose compatible scene metadata and hashes, but
must not bypass licensing restrictions. Browser-to-device file upload remains
available as an offline fallback and follows the same validation and installation
path.

Complete-set installation should prefer a versioned manifest/snapshot containing
relative paths, sizes, and SHA-256 values rather than requiring the ESP32 to keep
an entire GitHub ZIP in memory. It downloads into a staging generation on the TF
card, resumes missing or invalid files after interruption, validates the complete
snapshot, and then atomically switches the active library generation. The last
usable snapshot and unrelated user scenes remain untouched until activation
succeeds.

The page shows source/version, file count, total bytes, required/free space,
current file, aggregate progress, transfer rate, cancel/retry state, and final
accepted/warned/rejected counts. `Install`, `Update`, and `Repair` reuse valid
files whenever their hashes match. For the current reference library, capacity
planning uses 2,324 files and approximately 146 MiB installed, plus staging and
filesystem safety margin.

## Browser logs

An authenticated diagnostics page presents a bounded recent-log snapshot and then
follows new records through Server-Sent Events. It provides level/source filters,
search, pause/resume, reconnect status, and downloads for the current and rotated
log files. Viewing or downloading logs must not stop the display task.

Persistent logs use bounded rotation on the TF card. When the card is absent,
read-only, or full, logging continues in a bounded RAM ring buffer without a
write-retry loop. Wi-Fi passwords, administrator credentials, setup codes,
session/CSRF tokens, and other secrets are redacted before any log sink receives
them.

## Performance instrumentation

CPU usage is measurable. Enable ESP-IDF FreeRTOS run-time statistics and sample
task run times over a bounded interval. Report total utilization plus Core 0 and
Core 1 idle/utilization estimates, and attribute time to the display, renderer,
SCN, web, storage, Wi-Fi/MQTT, and idle tasks. Sampling is diagnostic work at a
low rate; it must not run in the frame loop or materially change the workload it
measures.

The diagnostics snapshot also includes:

- frame time, frames per second, and dropped/late frames;
- free/minimum internal heap and largest free block;
- free PSRAM and framebuffer allocation mode;
- task high-water marks;
- Wi-Fi RSSI and reconnect count;
- TF-card presence, free space, and I/O errors;
- uptime, reset reason, watchdog events, and NTP state.

CPU percentages are operational estimates rather than laboratory power
measurements. Dual-core totals and per-task percentages must be labelled clearly
so a task using one complete core is not mistakenly shown as using both cores.

## Statistics web page

The authenticated `/stats` page reads one immutable diagnostics snapshot and
receives low-rate updates through the same bounded event infrastructure as live
logs. It uses compact live cards plus short in-memory history charts, supports
pause/resume, and can download the current snapshot as JSON. Sampling and
broadcasting run outside the display task, and opening the page must not alter the
frame-rate or CPU measurements materially.

Display these groups:

- **System:** uptime, firmware/build, ESP-IDF version, chip/revision, CPU
  frequency, reset reason, active OTA partition, rollback/pending state, and
  watchdog/reset counters.
- **Temperature:** approximate internal ESP32-S3 chip temperature plus current,
  minimum, and maximum since boot.
- **CPU/tasks:** normalized total, Core 0 and Core 1 utilization, per-task runtime,
  and task stack high-water marks.
- **Memory:** current/minimum internal heap and PSRAM, largest free blocks,
  fragmentation indicators, and framebuffer allocation mode/size.
- **Display/playback:** current mode, fixed color/effect, brightness, matrix scale,
  FPS, average/maximum frame time, late/dropped frames, current scene, and playback
  queue length.
- **Storage/library:** TF-card mounted/read-only state, filesystem, total/used/free
  bytes, read/write errors, scene accepted/warned/rejected counts, last scan
  duration, and active transfer progress.
- **Network/time:** hostname, IP, SSID, RSSI, channel, reconnect count, network
  uptime, MQTT/broker status, last NTP success, clock source, and measured offset.
- **Web/diagnostics:** active authenticated sessions, live-log/stat clients,
  request/error counters, and log/RAM-ring utilization without exposing tokens or
  credentials.

The ESP32-S3 sensor measures temperature inside the silicon. The page must label
it **Chip temperature (approximate)** and explain that it is useful for trends and
thermal diagnostics, not room temperature. Current/minimum/maximum history and
warning thresholds are added only after the enclosed and unenclosed hardware
establishes a safe baseline.

The base Waveshare board does not provide trustworthy ambient temperature,
supply-voltage, current, or power-consumption telemetry to the firmware. Those
values remain `Unavailable` unless later external sensor hardware is explicitly
added and calibrated.

## Home Assistant

Home Assistant support is optional and uses its local MQTT integration with MQTT
device discovery. The ESP32 connects to the user's broker, publishes a birth/LWT
availability state, and registers one DMDClock device containing multiple
entities. MQTT credentials are stored in NVS and redacted from logs. Losing Home
Assistant, Wi-Fi, or the broker never stops the local clock, touch controls, SCN
playback, or web interface.

Initial entities:

- switches: display enabled and quiet/night mode;
- numbers: brightness and temporary-notification duration;
- selects: fixed Basic color, operating mode, and active playlist;
- buttons: next scene, previous scene, show clock, and resynchronize NTP;
- sensors: current scene, clock source, NTP state, firmware version, uptime,
  Wi-Fi RSSI, CPU utilization, free heap/PSRAM, frame rate, dropped frames, and
  TF-card free space;
- binary sensors: online, TF card present, time synchronized, and degraded
  renderer state;
- notification target: temporary text sent from Home Assistant to the DMD.

Useful automations include reducing brightness at night, turning the display off
when nobody is home, showing doorbell/alarm/calendar messages temporarily,
switching playlists for events, and monitoring low storage or abnormal CPU/frame
load. Remote log contents, passwords, and unrestricted download URLs are not
published through MQTT.

## Update boundaries

A normal update replaces only the inactive **DMDClock application partition**.
After validation and restart it becomes the active partition. It does not erase
the bootloader, partition table, NVS settings, factory/recovery image, or TF-card
SCN library. The embedded web UI is part of the application image and therefore
updates with DMDClock.

A complete merged-flash image is reserved for first installation, factory
recovery, or an explicitly versioned partition-table/bootloader migration. Those
operations use USB and are never presented as an ordinary web update. Theme and
renderer changes normally require only an application OTA; scene and playlist
changes require no firmware update because they are stored on the TF card.

## Delivery phases

Current phase status:

| Phase | Status | Remaining gate |
|---|---|---|
| 0 — Baseline and safety | **Partial** — exact board, vendor archive, COM4 flashing, and fixed production target are established | Photograph labels, test factory restore, document both USB paths, and freeze the partition-version policy |
| 1 — Canonical shared definitions | **Not started** | Generate both Windows and firmware themes from one validated source |
| 2 — Board bring-up | **Operational** — display, backlight, PSRAM, touch, UART, and FAT32 card work on the live board | Card-failure/power-loss tests, standalone framebuffer diagnostics, and complete boot inventory |
| 3 — DMD renderer | **Core complete** — packed framebuffer, exact 6× dots, brightness, glow, and double buffering run on hardware | Cross-platform hashes and measured CPU/PSRAM/frame-drop data |
| 4 — Fixed Basic colours | **Core complete** | Generated definitions, every-intensity verification, hashes, and performance measurements |
| 5 — Clock, date, and settings | **Operational** — clock, timezone, Wi-Fi, NTP, schedules, diagnostics, NVS, and SD settings backup work | Configurable NTP servers/interval, versioned NVS, factory reset, and longer offline tests |
| 6 — SCN and TF-card playback | **Operational for flat libraries** — all 2,324 prepared scenes and shared metadata are indexed from SD; bounded enable/settle retries recover stale cards after reset | Streaming reads, recursive cache, malformed-input parity, and card-removal/corruption handling |
| 7 — Touch and local web | **Daily controls complete** — touch overlay, web settings, diagnostics, API reference, default-on LAN boundary, logging, and reboot work | Optional future authentication/HTTPS, gestures, device-side downloads/uploads, live log viewer, full statistics page, and mDNS |
| 7b — Home Assistant | **Foundation implemented** — optional broker settings, retained discovery/state, birth/LWT, initial controls/diagnostics, status counters, and local setup QR work | Live Home Assistant/broker validation, TLS, remaining entities, notifications, and broker-failure soak testing |
| 7c — Gradient, Raster, Plasma | **Core complete** — all families, presets, Custom themes, Plasma, glow, and metadata colours run | Exhaustive intensity/hash/performance testing and automatic fallback |
| 8 — OTA and recovery | **Not started** | Partition design, signed validation, rollback, and tested USB recovery |
| 9 — Packaging and release | **Partial** — USB application/full packages, target manifest, checksums, and release-menu installer are implemented | Publish packages, add clean-board validation, then add future OTA/card artifacts |

### Phase 0 — Baseline and safety

- [ ] Photograph the board labels and confirm the module says `N16R8`.
- [x] Confirm the product is the 800×480 `7`, not the 1024×600 `7B`.
- [x] Download and archive the exact factory firmware and Waveshare example used
      for board initialization.
- [x] Record the UART connector, CH343 COM4 port, and explicit flash procedure.
- [ ] Record and test the native USB/JTAG connector and full factory recovery.
- [x] Establish the fixed 800×480 N16R8 production target.
- [ ] Define and freeze the partition-version policy.
- [ ] Run the Windows solution tests before merging shared metadata or generated
      theme-definition changes.

Exit: the board can always be returned to a known factory image.

### Phase 1 — Canonical shared definitions

- [ ] Add `shared/dmd/themes.json` with all current Basic, Plasma, Gradient, and
      Raster definitions.
- [ ] Add stable numeric IDs and schema validation.
- [ ] Extend `DmdClock.Tools` to generate C# and C++ tables.
- [ ] Replace handwritten Windows theme constants with generated C#.
- [ ] Generate C++ headers even before firmware uses them.
- [ ] Add `--check` mode and deterministic-output tests.
- [ ] Add Plasma lookup tables and existing reference vectors.

Exit: changing one canonical theme file changes both generated targets, and builds
fail if either generated target is stale.

### Phase 2 — Board bring-up

- [x] Create the ESP-IDF project from the official Waveshare board example.
- [x] Pin RGB timing, LCD GPIO mapping, CH422G backlight control, GT911 touch
      configuration, and PSRAM for the original 800×480 board.
- [x] Verify GT911 orientation and add TF-card pin handling on the
      physical board.
- [ ] Display color bars and framebuffer diagnostics.
- [x] Read touch points and validate orientation on the live overlay.
- [x] Mount and read/write the prepared FAT32 TF card.
- [ ] Test card removal, corruption, full-card, and power-loss recovery.
- [ ] Print firmware, board, flash, PSRAM, and partition versions at boot.

Exit: display, touch, PSRAM, TF card, and serial recovery work independently.

### Phase 3 — DMD renderer

- [x] Implement the packed 128×32 four-bit framebuffer.
- [x] Draw separated round dots at exact 6× scale.
- [x] Implement brightness and the lightweight configurable glow.
- [x] Use double-buffered frame-boundary swaps for the production RGB panel.
- [ ] Validate synthetic frames against Windows framebuffer hashes.
- [ ] Record refresh rate, CPU load, PSRAM bandwidth, and dropped frames.

Exit: static and animated test frames remain stable without tearing or watchdog
resets.

### Phase 4 — Fixed Basic colors

- [ ] Consume only the generated C++ theme definitions.
- [x] Implement the fixed Basic renderer, brightness, and black background.
- [ ] Verify every Basic color with intensity levels 0–15.
- [ ] Add a cross-platform test that hashes one rendered frame per Basic color.
- [ ] Record per-core CPU/task use, frame time, heap, PSRAM, and dropped frames.

Exit: Windows and ESP32 produce matching fixed-color decisions, and the simple
interface remains stable before advanced effects are introduced.

### Phase 5 — Clock, date, and settings

- [ ] Convert approved DotClk bitmap fonts to generated firmware assets.
- [x] Implement time formatting, optional seconds, 12/24-hour display, and
      persisted timezone selection.
- [x] Add Wi-Fi provisioning, manual sync, timezone, and daylight-saving
      behaviour.
- [ ] Make the primary/secondary NTP servers and synchronization interval
      configurable and validated.
- [x] Add automatic primary/secondary NTP, manual synchronization, browser-time
      fallback, and live source/sync state to the device remote.
- [x] Show the configured Wi-Fi name and `IP` with its assigned DHCP address or
      connection state on a dedicated 20-second startup screen. Hide the setup
      IP after DHCP succeeds and never display the Wi-Fi password.
- [x] Show the application build and monotonic `days hh:mm:ss` uptime at the
      bottom of the web remote.
- [x] Publish GT911 event count, last coordinates/status byte, interrupt level,
      and I2C errors through the diagnostics state used by the web remote.
- [x] Use the MAC-derived `DMDClock-XXXX` access-point name as the device name,
      station/AP hostname, startup-screen identity, API value, and web title so
      multiple clocks remain distinguishable on the same network.
- [x] Acknowledge GT911 status on every poll, including no-data polls, matching
      the Espressif driver and preventing a stuck-low touch interrupt.
- [x] Follow network startup with five guided touch targets, five seconds each,
      live event/coordinate feedback, and a five-second result screen.
- [x] Show scene metadata without redundant `PINBALL` and `SCENE` prefixes:
      game, scene title, year, then manufacturer.
- [x] Keep `CONFIG_LCD_RGB_RESTART_IN_VSYNC` disabled because ESP-IDF 5.5.2
      restarts RGB DMA on every VSYNC when it is enabled; use double-buffered
      frame-boundary handoff and diagnose actual underruns separately.
- [x] Show last synchronization, elapsed age, clock source, progress, and failure
      state through the diagnostics API and web remote.
- [ ] Measure and expose the actual NTP offset independently of the browser
      comparison.
- [ ] Store settings in versioned NVS records.
- [x] Migrate existing NVS settings into the editable SD settings backup and
      prefer valid SD settings at boot.
- [ ] Add reset-without-erasing-factory-recovery.
- [x] Preserve the running clock across temporary network or NTP loss.

Exit: the device boots directly into a reliable clock and retains settings.

### Phase 6 — SCN and TF-card playback

- [x] Port the bounds-checked SCN parser and validate every frame/storyboard
      boundary before decoding.
- [ ] Replace whole-file loading with bounded streaming reads.
- [x] Reuse an 11-scene compatibility corpus in QEMU.
- [ ] Reuse the desktop malformed-input fixtures in firmware tests.
- [x] Implement first/regular/final storyboard timing, masks, blanking, clock
      layers, one-shot completion, and Windows-style clock/scene cycling for the
      QEMU corpus and SD library.
- [x] Resolve the ESP32 scene catalog from the same schema-1
      `scene-metadata.json` used by Windows, including exact-file and
      longest-prefix rules, while leaving timing and masks in the SCN.
- [x] Scan the complete flat TF-card scene directory into a compact PSRAM index.
- [ ] Add recursive subdirectory scanning and a rebuildable on-card cache.
- [x] Add sequential/random playback and automatic clock/animation cycles for
      the QEMU corpus and SD library.
- [ ] Define safe behavior for card removal, corrupt files, and low memory.

Exit: the agreed compatibility corpus produces the same frames and timings as the
Windows reference within documented clock tolerance.

### Phase 7 — Touch and local web settings

- [x] Add shared touch/web actions for next pinball, next scene, colour family,
      next theme, information, glow, NTP sync, show clock, touch test, and
      confirmed device reboot.
- [x] Add an optimized per-dot glow halo, persistent 0–100% strength, and
      matching local/web glow controls.
- [x] Show the live device timestamp, browser comparison, NTP state, selected
      scene, selected colour family/preset, and cycle settings in the web remote.
- [x] Apply the Scene information checkbox to the physical display immediately
      and keep it synchronized with changes made through other controls.
- [x] Add a device-hosted `/api-docs` reference linked from the remote, covering
      all current GET/POST routes, partial settings fields, named actions,
      copyable examples, persistence behavior, and the current trusted-LAN
      security model.
- [x] Add a confirmation-protected web reboot control backed by the documented
      `reboot` API action, with a delayed restart so callers receive success
      before the connection drops.
- [x] Show the effective On/Off screen state in the web diagnostics footer,
      including whether Off comes from the master switch or weekly schedule and
      whether a scheduled-off screen is temporarily awake after touch.
- [x] Make the local button row transient: eight seconds at full visibility,
      a short fade, and a safe reveal-only first touch once hidden.
- [ ] Single tap toggles the transient control overlay.
- [ ] Swipe selects previous/next animation.
- [ ] Long press opens settings.
- [ ] Implement first-run administrator enrollment with a per-device setup code,
      forced password creation, salted verification, sessions, rate limiting, and
      physical/USB password recovery.
- [x] Reproduce colour-family swatches and current-selection summaries.
- [x] Add scene, clock, brightness, colour, network, schedule, and NTP settings.
- [x] Provide `Sync NTP` with non-blocking status and last-sync age.
- [ ] Add editable NTP hostnames/intervals with validation and apply them without
      rebooting.
- [ ] Let the device download selected SCN files over HTTPS to temporary TF-card
      paths, validate them, atomically install them, and report progress/cancel/
      failure state in the browser.
- [ ] Add one-click complete DotClk scene-set `Install`, `Update`, and `Repair`
      using a resumable, hash-verified staged snapshot from the original source.
- [ ] Preserve the active complete set and unrelated user scenes until the new
      snapshot has passed full validation and is atomically activated.
- [ ] Keep authenticated browser upload as an offline SCN import path.
- [ ] Stream redacted logs to the authenticated browser with Server-Sent Events
      and make bounded current/rotated files downloadable.
- [ ] Add `/stats` with live cards, short history, pause/resume, JSON export, and
      low-rate Server-Sent Events for every supported diagnostics group.
- [x] Publish a compact diagnostics footer and `/api/state` values for chip
      temperature, Wi-Fi, memory, SD, time, reset, rendering, touch, settings,
      screen state, build, and uptime.
- [x] Label internal temperature as chip-only and not ambient.
- [ ] Establish enclosed/unenclosed temperature baselines and warning thresholds.
- [ ] Serve the same settings on `dmdclock.local`.
- [x] Keep HTTP request handling outside the display render loop.
- [ ] Stress-test display responsiveness under concurrent HTTP, SD, and logging
      activity.

Exit: all daily settings can be changed without reflashing or connecting a PC.

### Phase 7b — Home Assistant

- [x] Add optional local MQTT broker configuration, disabled by default, with
      credentials mirrored in NVS and the explicitly plaintext SD backup.
- [x] Publish Home Assistant MQTT discovery and birth/LWT availability.
- [ ] Add the fixed-color, brightness, mode, scene, NTP, notification, and
      diagnostic entities defined above.
- [x] Add the first display, brightness, scene-navigation, NTP, playback, system,
      storage, Wi-Fi, time, and firmware entities.
- [x] Validate bounded commands, publish state at a low rate/on change, and keep
      MQTT work off the display task.
- [ ] Test discovery, broker loss/reconnect, retained state, and operation with
      Home Assistant disabled.
- [x] Add a credential-free on-screen QR for the current local setup URL; state
      clearly that Home Assistant MQTT discovery does not use QR pairing.

Exit: Home Assistant can monitor and control useful DMDClock functions, while the
device remains a standalone clock.

### Phase 7c — Gradient, Raster, and Plasma

- [x] Implement Gradient and Raster with the stable Windows preset IDs.
- [x] Port the frozen integer Plasma field, phase calculation, cyclic palette
      interpolation, eight presets plus Custom, and compare all four reference
      vectors at firmware startup.
- [x] Add persistent Plasma palette/custom-stop/cycle settings, API/web controls,
      shared colour selection, and a 30 FPS maximum animation scheduler.
- [x] Give Basic, Gradient, Raster, and Plasma separate persistent Custom themes
      in the firmware API and web remote.
- [x] Render scene information as one compact metadata row with selectable
      discreet-grey, follow-theme, and custom standalone colours.
- [x] Keep editable, backup-friendly settings in `/dmd/config/settings.json`
      with NVS fallback; web changes update both stores and SD wins at boot.
- [x] Move the guided touch test from mandatory startup into a web action.
- [x] Publish chip, network, memory, storage, reset, rendering, touch, time, and
      settings-save diagnostics for the web footer and future HA discovery.
- [ ] Verify every advanced theme with intensity levels 0–15.
- [ ] Add a cross-platform framebuffer hash for every advanced theme.
- [ ] Compare CPU, task, frame-time, PSRAM-bandwidth, and dropped-frame metrics
      against the fixed-color baseline.
- [ ] Fall back safely to a fixed Basic color when a performance budget is not met.

Exit: advanced effects match Windows and remain responsive without compromising
the proven fixed-color path.

### Phase 7d — Hot-core glow

- [x] Add shared optional Hot-core settings with Classic warm centre, Follow theme,
      and Dual colour modes.
- [x] Implement the precomputed ESP32 three-ring/LUT renderer and retain the
      current lightweight glow as its measured fallback.
- [ ] Verify monotonic output for all 16 intensities and black separation in a
      worst-case all-dots-on frame.
- [ ] Measure Basic, Plasma, and SCN playback at the strongest supported glow;
      preserve the 30 FPS budget and touch/web responsiveness.

Exit: the effect looks hot and luminous without joining adjacent dots, obscuring
the theme colour, or destabilizing the fixed-colour fallback.

### Later project — TTF/OTF fonts

- [ ] Evaluate direct on-device TTF/OTF rasterization against build-time or
      upload-time conversion into compact bitmap glyph assets.
- [ ] Implement the preferred deterministic converter with explicit input hash,
      pixel sizes, Unicode subset, four-bit intensity atlas, transparency masks,
      glyph metrics, kerning, output manifest, and reproducible C++/test fixtures.
- [ ] Make converter check mode fail when generated firmware font assets are stale
      or differ from the canonical TTF/OTF input and conversion settings.
- [ ] Measure firmware size, font storage, heap/PSRAM, glyph-cache behavior,
      startup time, render latency, and display-task interference.
- [ ] Allow direct on-device outline rendering only if those measurements show a
      material benefit over the generated atlas without exceeding clock,
      responsiveness, memory, or recovery budgets.
- [ ] Define supported Unicode ranges, font-size limits, glyph-count limits,
      fallback behavior, and malformed-font rejection.
- [ ] Keep a built-in bitmap font that works when an uploaded font is missing,
      invalid, too large, or removed with the TF card.
- [ ] If runtime font upload is selected, add authenticated web upload, preview,
      activation, deletion, and recovery without allowing a font to prevent boot.
- [ ] Keep font licensing outside the ESP32 implementation gates; local
      conversion, upload, testing, and use are governed only by technical limits.

Exit: optional TTF/OTF input cannot degrade clock reliability and has a measured,
documented resource budget. This project is not part of the first ESP32 release.

### Phase 8 — OTA, rollback, and recovery

- [ ] Define factory, OTA A/B, NVS, and asset partitions.
- [ ] Make routine OTA packages application-only so NVS and TF-card content remain
      untouched.
- [ ] Sign or authenticate release manifests before OTA installation.
- [ ] Validate target ID, size, checksum, and minimum bootloader version.
- [ ] Mark a new image valid only after display, settings, and watchdog startup
      checks pass.
- [ ] Roll back automatically after failed startup.
- [ ] Keep USB recovery documented and tested.

Exit: interrupted or faulty updates return to a working firmware without opening
the enclosure.

### Phase 9 — Packaging and release

- [ ] Generate `merged-flash.bin` for first installation.
- [ ] Generate an OTA application image for upgrades.
- [ ] Generate a TF-card starter package without bundled original scene content.
- [x] Produce a USB release ZIP with bootloader, partition table, and application
      images for full or application-only flashing.
- [x] Produce a target-specific manifest, flash offsets, build metadata, and
      SHA-256 checksums.
- [x] Provide one PowerShell installer/updater that selects a compatible GitHub
      release, verifies it, and optionally flashes an explicit COM port.
- [ ] Add local release validation that flashes a clean board and performs smoke
      tests.
- [x] Keep Windows and ESP32 artifacts separate while allowing the GitHub release
      publisher to validate and include both with `-IncludeEsp32`.

Exit: a user can install, recover, and update the Waveshare board using documented
local tools.

## Local artifact layout

```text
output/esp32/current/
├─ waveshare-esp32-s3-touch-lcd-7/
│  ├─ bootloader.bin
│  ├─ partition-table.bin
│  ├─ dmdclock.bin
│  ├─ dmdclock-ota.bin
│  ├─ merged-flash.bin
│  ├─ flash-command.txt
│  ├─ manifest.json
│  ├─ SHA256SUMS.txt
│  └─ sdcard/
└─ reports/
   ├─ size.txt
   ├─ tests.xml
   ├─ framebuffer-hashes.json
   └─ toolchain.json
```

## Testing layers

1. **Generator tests:** schema, stable IDs, deterministic output, stale-file
   detection.
2. **Host-native firmware tests:** palettes, Plasma, settings, SCN parsing, timing,
   and malformed inputs without requiring the board.
3. **.NET reference tests:** existing core tests plus generated-data validation.
4. **Cross-platform contract tests:** identical vector inputs and output hashes.
5. **Board smoke tests:** display, touch, PSRAM, TF card, Wi-Fi, SNTP, and watchdog.
6. **Hardware-in-the-loop tests:** flash, serial boot protocol, rendered-frame
   checksums, OTA, rollback, and recovery.

Ordinary local builds run layers 1–4. Board tests are explicit because they require
connected hardware and can modify its flash.

## Build pipeline boundaries

The firmware has a separate build pipeline from Windows:

```text
shared generation ─┬─► Windows build/test/package
                   └─► ESP32 build/test/package/flash
```

The local workstation is the primary build executor during development. A later
GitHub workflow may independently verify reproducibility and attach artifacts, but
it is not the only way to build or recover the device.

Firmware pipeline triggers:

- changes under `firmware/**`;
- changes under `shared/**`;
- generator changes under `tools/DmdClock.Tools/**`;
- firmware scripts or pipeline configuration.

Windows pipeline triggers also include `shared/**` and generator changes. A shared
theme change must therefore exercise both targets.

## Versioning and compatibility

Record these independently:

- product version;
- Git commit;
- board target ID;
- ESP-IDF version/commit;
- shared-data schema version and hash;
- settings schema version;
- partition-table version;
- minimum compatible bootloader and OTA version.

Do not reuse a settings field ID for a different meaning. Do not renumber themes.
Migrations are forward-only functions with test fixtures for every released schema.

## Principal risks

- RGB refresh competes with CPU and PSRAM bandwidth.
- Full-screen glow may be too expensive and needs a measured fallback.
- TF-card reads can stall rendering unless buffering is strict.
- Sudden power loss can corrupt writable FAT data; settings remain in NVS and
  library caches must be rebuildable.
- A wrong board or LCD timing package can produce a black screen.
- OTA partition mistakes can make recovery unnecessarily difficult.
- Hand-copied theme constants will diverge; generated shared data is mandatory.
- Original scenes remain outside public firmware and TF-card packages; users
  obtain them separately from their original source.

## Definition of done for the first ESP32-S3 release

- The fixed Waveshare 7-inch target boots from a clean flash.
- Clock/date and the agreed `.scn` compatibility library play reliably.
- Basic, Plasma, Gradient, and Raster output passes shared contract tests.
- Theme changes made in canonical shared data appear in both Windows and ESP32
  builds without manual duplication.
- Touch, web settings, TF card, Wi-Fi/SNTP, NVS migration, OTA, rollback, and USB
  recovery are documented and tested.
- A 24-hour hardware soak has no watchdog reset, unrecoverable storage failure,
  memory leak, or persistent display corruption.
- Local scripts reproduce all release artifacts and checksums on the recorded
  workstation without ChatGPT-hosted compilation.
