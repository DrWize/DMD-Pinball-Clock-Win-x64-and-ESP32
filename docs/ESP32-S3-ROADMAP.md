# DMDClock ESP32-S3 roadmap

Project repository:
[DrWize/DMDClock-Windows-x64](https://github.com/DrWize/DMDClock-Windows-x64).
ESP32 work remains on the dedicated `test/esp32-s3` branch until physical-board
validation is complete.

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
- Synchronize time over Wi-Fi and preserve a useful offline clock.
- Support local USB flashing, serial diagnostics, OTA updates, rollback, and a
  recoverable factory image.
- Build, test, package, flash, and monitor on the developer's local Windows
  workstation. ChatGPT may edit source and run the local scripts, but compilation
  must not depend on a ChatGPT-hosted build service.

## Non-goals for the first firmware release

- Running .NET or Avalonia on the ESP32-S3.
- OpenType/TTF rendering.
- The full desktop Scene Reviewer on the device.
- Windows installer, screensaver, window-management, or file-picker behavior.
- Supporting the Waveshare 7B, other LCD timings, or external physical DMDs from
  the first board package.
- Bundling resources whose redistribution rights have not been confirmed.

## Build-readiness audit

This is the current repository and workstation state as verified on 2026-07-28.
It is the starting point for the ordered plan below.

| Area | Current state | Required fix |
|---|---|---|
| Windows reference | Plasma and the versioned release pipeline are merged into `master`; the expanded color controls build locally | Preserve this baseline through every shared-data migration |
| Working branch | ESP32 work is published separately on `test/esp32-s3` | Keep it isolated until the physical-board gates pass |
| Theme definitions | Repeated across settings, renderer, menu labels, swatches, and localization | Move stable IDs and RGB/band data into canonical shared definitions |
| Plasma | Windows and ESP32 use the frozen integer field, eight palettes plus Custom, and startup vectors | Add cross-platform palette and framebuffer hash tests |
| ESP32 firmware | Barebones ESP-IDF firmware, QEMU display, SCN playback, Plasma, NTP, touch actions, and web control compile | Validate the production profile on the exact physical board |
| Shared inputs | No `shared` directory | Add schema-validated canonical definitions and deterministic generation |
| ESP32 scripts | Doctor, vendor-example build, production/QEMU build, QEMU run, and explicit-port flash entry points work | Add packaging and hardware-test automation after the board arrives |
| Build automation | No `.github/workflows` directory | Keep local builds primary; add independent verification only after local firmware is reproducible |
| Local .NET | Workspace-local .NET 10 is working | Reuse it for the shared generator and Windows contract tests |
| Local firmware tools | Pinned ESP-IDF 5.5.2 toolchain is installed and a full ESP32-S3 build passes | Keep Arduino and PlatformIO out of the primary pipeline |
| Local machine | i7-13700KF, 24 threads, 63.8 GB RAM | Default local builds to 20 jobs |
| Connected board | No serial port or relevant USB device was detected | Connect the UART USB port, install/verify its driver, and record the COM port |
| Exact board revision | Product information suggests the original 800×480 board | Confirm `ESP32-S3-Touch-LCD-7` and `N16R8` from physical markings; do not assume it is not a 7B |
| Recovery | Official package and its `Firmware/*.bin` recovery images are archived under ignored `external/` | Identify the correct factory image and test its documented `0x00` restore before custom flashing |
| TF card | Onboard slot is known but no card has been verified | Prepare a FAT32 test card and pass the vendor SD example |
| Scene redistribution | Original scenes have redistribution caveats | Keep them out of public firmware/TF packages and download them from their original source |
| OTA/recovery | Not designed or tested | Defer OTA until USB recovery and a stable partition table work |

## Required resources

### Hardware on the desk

- [ ] Waveshare `ESP32-S3-Touch-LCD-7`, physically confirmed as 800×480.
- [ ] Module marking physically confirmed as `ESP32-S3-WROOM-1-N16R8`.
- [ ] Data-capable USB cable connected to the port labeled `UART` for initial
      flashing and serial logs.
- [ ] A second data-capable cable for native USB/JTAG testing if the board exposes
      both connectors.
- [ ] Stable 5 V USB power.
- [ ] Reliable TF/microSD card prepared as FAT32.
- [ ] A local folder containing the vendor schematic, current example source,
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

## What must be fixed before feature development

### P0 — repository and recovery safety

1. Stabilize and commit the current Windows color/menu work.
2. Create `feature/esp32-waveshare7` from that known baseline.
3. Confirm the exact physical board and module revision.
4. Archive the vendor factory image and test restoring it.
5. Record the correct USB connector, driver, COM port, flash command, and reset/
   boot-button sequence.

No custom firmware should be flashed before these five items are complete.

### P0 — eliminate cross-platform color drift

The current color implementation contains multiple handwritten representations:

- enum IDs and Plasma stops in `DmdClockSettings.cs`;
- dot, Gradient, and Raster RGB data in `DmdDisplay.cs`;
- visual menu swatches and background defaults in `MainWindow.axaml.cs`;
- display names in localization JSON.

Before adding the same constants to firmware:

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

## Immediate next session

The workstation portion of Gate 2 is complete. When the board arrives, stop after
the remaining Gates 0–3 work:

1. Finish and commit the current Windows branch.
2. Confirm that the physical board is the 800×480 `7` with an `N16R8` module.
3. Connect the port labeled `UART`, run `Doctor.ps1`, and record its COM port.
4. If Windows does not create a COM port, install the USB drivers from an
   Administrator terminal and rerun the doctor.
5. Test the archived factory recovery image at the documented `0x00` address.
6. Flash and run the untouched Waveshare LVGL and TF examples.

Only then should shared source generation and custom firmware begin. This order
separates board/toolchain problems from DMDClock problems and preserves a known
recovery path.

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
DMDClock-Windows-x64/
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
│     ├─ Build-Firmware.ps1
│     ├─ Flash-Firmware.ps1
│     ├─ Monitor-Firmware.ps1
│     └─ Package-Firmware.ps1
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
.\scripts\esp32\Build-Firmware.ps1 -Configuration Debug -Jobs 20

# Explicit hardware operations; never part of an ordinary build.
.\scripts\esp32\Flash-Firmware.ps1 -Port COM5
.\scripts\esp32\Monitor-Firmware.ps1 -Port COM5

# Produce install, OTA, TF-card, manifest, and checksum artifacts.
.\scripts\esp32\Package-Firmware.ps1 -Configuration Release -Jobs 20
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
  assets, one fallback bitmap font, a small fallback scene, and NVS.
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

### Phase 0 — Baseline and safety

- [ ] Photograph the board labels and confirm the module says `N16R8`.
- [ ] Confirm the product is the 800×480 `7`, not the 1024×600 `7B`.
- [ ] Download and archive the exact factory firmware and Waveshare example used
      for board initialization.
- [ ] Record both USB connectors, detected COM ports, and recovery procedure.
- [ ] Establish the fixed board target ID and partition-version policy.
- [ ] Keep all Windows tests green before firmware structure is introduced.

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
- [ ] Verify GT911 orientation/calibration and add TF-card pin handling on the
      physical board.
- [ ] Display color bars and framebuffer diagnostics.
- [ ] Read touch points and validate orientation/calibration.
- [ ] Mount a FAT32 TF card and run read/write/power-loss checks.
- [ ] Print firmware, board, flash, PSRAM, and partition versions at boot.

Exit: display, touch, PSRAM, TF card, and serial recovery work independently.

### Phase 3 — DMD renderer

- [x] Implement the packed 128×32 four-bit framebuffer.
- [x] Draw separated round dots at exact 6× scale.
- [ ] Implement brightness and optional glow within measured frame-time limits.
- [ ] Add single- and double-buffer modes for comparison.
- [ ] Validate synthetic frames against Windows framebuffer hashes.
- [ ] Record refresh rate, CPU load, PSRAM bandwidth, and dropped frames.

Exit: static and animated test frames remain stable without tearing or watchdog
resets.

### Phase 4 — Fixed Basic colors

- [ ] Consume only the generated C++ theme definitions.
- [ ] Implement the fixed Basic renderer, brightness, and explicit backgrounds.
- [ ] Verify every Basic color with intensity levels 0–15.
- [ ] Add a cross-platform test that hashes one rendered frame per Basic color.
- [ ] Record per-core CPU/task use, frame time, heap, PSRAM, and dropped frames.

Exit: Windows and ESP32 produce matching fixed-color decisions, and the simple
interface remains stable before advanced effects are introduced.

### Phase 5 — Clock, date, and settings

- [ ] Convert approved DotClk bitmap fonts to generated firmware assets.
- [x] Implement time formatting, optional seconds, 12/24-hour display, and
      persisted timezone selection.
- [ ] Add Wi-Fi provisioning, configurable primary/secondary NTP servers,
      synchronization interval, manual sync, timezone, and daylight-saving
      behavior.
- [x] Add automatic primary/secondary NTP, manual synchronization, browser-time
      fallback, and live source/sync state to the current barebones remote.
- [ ] Show last synchronization, clock source, offset, and failure state through
      the diagnostics API.
- [ ] Store settings in versioned NVS records.
- [ ] Add settings migration and reset-without-erasing-factory-recovery.
- [ ] Preserve a useful clock across temporary network loss.

Exit: the device boots directly into a reliable clock and retains settings.

### Phase 6 — SCN and TF-card playback

- [ ] Port SCN parsing with bounds-checked streaming reads.
- [ ] Reuse the desktop SCN corpus and malformed-input fixtures.
- [x] Implement first/regular/final storyboard timing, masks, blanking, clock
      layers, one-shot completion, and Windows-style clock/scene cycling for the
      embedded test set.
- [x] Resolve the ESP32 scene catalog from the same schema-1
      `scene-metadata.json` used by Windows, including exact-file and
      longest-prefix rules, while leaving timing and masks in the SCN.
- [ ] Add recursive TF-card library scanning and a compact cached index.
- [x] Add sequential/random playback and automatic clock/animation cycles for
      the embedded test set.
- [ ] Define safe behavior for card removal, corrupt files, and low memory.

Exit: the agreed compatibility corpus produces the same frames and timings as the
Windows reference within documented clock tolerance.

### Phase 7 — Touch and local web settings

- [x] Add the barebones shared touch/web actions for previous/next colour,
      information on/off, manual NTP sync, previous/next scene, and show clock.
- [x] Add an optimized per-dot glow halo, persistent 0–100% strength, and
      matching local/web glow controls.
- [x] Show the live device timestamp, browser comparison, NTP state, selected
      scene, selected colour family/preset, and cycle settings in the web remote.
- [x] Make the local button row transient: eight seconds at full visibility,
      a short fade, and a safe reveal-only first touch once hidden.
- [ ] Single tap toggles the transient control overlay.
- [ ] Swipe selects previous/next animation.
- [ ] Long press opens settings.
- [ ] Implement first-run administrator enrollment with a per-device setup code,
      forced password creation, salted verification, sessions, rate limiting, and
      physical/USB password recovery.
- [ ] Reproduce color-family swatches and current-selection summaries.
- [ ] Add scene, clock, date, brightness, background, network, and NTP settings.
- [ ] Validate NTP hostnames and intervals, apply changes without rebooting, and
      provide `Sync now` with non-blocking status updates.
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
- [ ] Label internal temperature as approximate chip temperature, establish
      enclosed/unenclosed baselines, and avoid claiming ambient or power
      measurements without external sensors.
- [ ] Serve the same settings on `dmdclock.local`.
- [ ] Ensure the display task remains independent of UI and HTTP activity.

Exit: all daily settings can be changed without reflashing or connecting a PC.

### Phase 7b — Home Assistant

- [ ] Add optional MQTT broker configuration and encrypted credential handling.
- [ ] Publish Home Assistant MQTT device discovery and birth/LWT availability.
- [ ] Add the fixed-color, brightness, mode, scene, NTP, notification, and
      diagnostic entities defined above.
- [ ] Rate-limit and validate commands and keep MQTT work off the display task.
- [ ] Test discovery, broker loss/reconnect, retained state, and operation with
      Home Assistant disabled.

Exit: Home Assistant can monitor and control useful DMDClock functions, while the
device remains a standalone clock.

### Phase 7c — Gradient, Raster, and Plasma

- [x] Implement Gradient and Raster with the stable Windows preset IDs.
- [x] Port the frozen integer Plasma field, phase calculation, cyclic palette
      interpolation, eight presets plus Custom, and compare all four reference
      vectors at firmware startup.
- [x] Add persistent Plasma palette/custom-stop/cycle settings, API/web controls,
      shared colour selection, and a 30 FPS maximum animation scheduler.
- [ ] Verify every advanced theme with intensity levels 0–15.
- [ ] Add a cross-platform framebuffer hash for every advanced theme.
- [ ] Compare CPU, task, frame-time, PSRAM-bandwidth, and dropped-frame metrics
      against the fixed-color baseline.
- [ ] Fall back safely to a fixed Basic color when a performance budget is not met.

Exit: advanced effects match Windows and remain responsive without compromising
the proven fixed-color path.

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
- [ ] Produce `manifest.json`, flash offsets, build metadata, and SHA-256 checksums.
- [ ] Add local release validation that flashes a clean board and performs smoke
      tests.
- [ ] Keep Windows and ESP32 artifacts separate but allow one GitHub release to
      contain both after the firmware reaches release quality.

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
- Embedded DotClk fonts and original scenes require redistribution review before
  public firmware or TF-card packages include them.

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
