# DMDClock development history

Completed roadmap work was moved here on 2026-08-14 so the root
`TODO.md` remains an active backlog. Items retain their original wording and
heading context; release-level evidence remains available in Git history and
published GitHub releases.

## Windows

### DMDClock for Windows x64 — development TODO / Current baseline / Repository integration and cleanup — reviewed 2026-08-12

- [x] Integrate `c24ecb5` and `b86ed2e` into the default branch (`master`, not
      `main`), rerun release validation, and push the resulting branch state.
- [x] Remove only clean, fully merged feature branches and stale worktrees; audit
      local and remote branch reachability before each deletion and retain any
      branch containing unique or uncommitted work.
- [x] Document current Wi-Fi storage, plain-text SD backup, recovery AP password,
      lack of web login/HTTPS, release links, and compatible enclosure links.
- [x] Keep font-licensing research outside the release gates; retain source
      attribution and recorded hashes without making it part of this release work.

### DMDClock for Windows x64 — development TODO / Priority 0 — unified scene-library downloads on every platform / P0.1 — shared catalog and product language

- [x] Keep stable catalog IDs for `dotclk-original` and `drwize-complete` and
      expose display name, description, version, scene count, compressed size,
      installed size, SHA-256, supported platforms, and download/manifest URLs.
- [x] Present **DMD-Large — 2,416 scenes, includes Original DotCLK-Orig
      (preferred)** and **Original DotCLK-Orig — 2,324 scenes** consistently on
      every platform.

### DMDClock for Windows x64 — development TODO / Priority 0 — unified scene-library downloads on every platform / P0.4 — tests and release acceptance

- [x] Add .NET tests for both catalog choices, destination isolation, selection,
      cancellation, corrupt downloads, and upgrading one installed pack without
      changing the other.

### DMDClock standalone installer / Installer roadmap and TODO / Phase 1 — package foundation

- [x] Select a single-EXE Windows installer tool
- [x] Add a stable installer application ID
- [x] Use a non-admin per-user installation directory
- [x] Package the standalone EXE, SCR, translations, font, reports, documentation,
      and screenshots
- [x] Add a repeatable PowerShell installer build
- [x] Generate installer SHA-256 and build metadata
- [x] Archive the previous installer package

### DMDClock standalone installer / Installer roadmap and TODO / Phase 2 — Windows integration

- [x] Add Start Menu application, configuration, preview, settings, and uninstall shortcuts
- [x] Add Start Menu and finish-page links to the original DotClk scene source
- [x] Add optional Desktop and start-with-Windows tasks
- [x] Add optional screensaver activation
- [x] Preserve and restore the previous screensaver on uninstall
- [x] Leave a screensaver selected later by the user unchanged
- [x] Preserve DMDClock AppData settings during upgrades and uninstall

### DMDClock standalone installer / Installer roadmap and TODO / Phase 3 — automated local validation

- [x] Compile the installer from a fresh standalone build
- [x] Verify the installer contains all required files
- [x] Run a silent install into an empty directory
- [x] Verify EXE and SCR hashes match the standalone inputs
- [x] Verify optional screensaver activation changes the expected HKCU values
- [x] Run a silent uninstall and verify previous screensaver restoration
- [x] Verify uninstall removes installed program files but retains DMDClock AppData
- [x] Verify a repeat installation preserves the original screensaver restore point
- [x] Test an in-place upgrade over an older installer build

### DMDClock standalone installer / Installer roadmap and TODO / Phase 4 — release validation

- [x] Test the interactive wizard on clean Windows 10 x64
- [x] Test the interactive wizard on clean Windows 11 x64
- [x] Test without an installed .NET runtime
- [x] Verify Start Menu, Desktop, startup, configuration, preview, and uninstall shortcuts
- [x] Verify add/remove programs metadata and icon
- [x] Skip paid SmartScreen/antivirus reputation testing for this hobby release
- [x] Record Authenticode signing as optional rather than a release requirement;
      paid signing certificates or services are not currently justified
- [x] Add the setup EXE, portable and standalone ZIPs, build information, and
      generated checksums to the repeatable `Publish-GitHubRelease.ps1` workflow
- [x] Publish and verify the `v1.0.0` GitHub pre-release
- [x] Keep font-licensing research outside the release gates while retaining source
      attribution and recorded hashes

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 3 — animation-library selection / Main application selection

- [x] Make the main selector and Scene Reviewer read and write the same atomic
      `%LOCALAPPDATA%\DmdClock\library-selections.json` selection document
- [x] Apply the same selection resolver and shared selection document to both regular
      DMDClock playback and fullscreen screensaver playback at the same time
- [x] Watch the shared selection document for atomic changes so an already-running app
      or screensaver safely refreshes its playback queue at the next scene boundary
      without requiring a restart
- [x] Make the selector and Scene Reviewer available from the regular app and
      screensaver configuration mode while keeping fullscreen `/s` playback free of
      configuration controls
- [x] Put selection models, persistence, reconciliation, catalog building, filtering,
      and playback-list generation in `DmdClock.Core`; keep the selector and reviewer
      windows plus rendering behavior in `DmdClock.App`

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 3 — animation-library selection / Metadata packaging and GitHub updates

- [x] Include the baseline metadata JSON in every regular ZIP, standalone EXE package,
      screensaver package, and installer build so a clean clone and every published
      build have useful metadata without a separate download

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 5 — installer and release automation

- [x] Select Inno Setup and add a conventional non-admin per-user installer
- [x] Package standalone `DmdClock.App.exe`, `DMDClock.scr`, translations, font,
      reports, checksums, and user documentation
- [x] Add Start Menu shortcuts plus optional Desktop and automatic-start shortcuts
- [x] Add installed instructions plus Start Menu and finish-page links showing
      where and how to obtain original DotClk `.scn` files
- [x] Add optional screensaver activation that restores the previous screensaver on uninstall
- [x] Add `scripts\Build-Installer.ps1`, installer checksums, metadata, and archiving
- [x] Complete automated silent install, screensaver registration, repeat-install,
      checksum, AppData-preservation, and uninstall tests
- [x] Test an in-place upgrade from an older installer build
- [x] Test the interactive installer on clean Windows 10 and Windows 11 without .NET
- [x] Add `scripts\Publish-GitHubRelease.ps1` with build-ID checks, release asset
      validation, generated SHA-256 checksums, dry-run support, and GitHub upload
- [x] Publish the installer, portable ZIP, standalone ZIP, build information, and
      release checksums as the `v1.0.0` GitHub pre-release
- [x] Decide Authenticode signing is not required for the current release:
      paid signing certificates or services are not justified for this
      Sweden-based hobby project

### Replace selected local repositories with fresh clones. / Completed work

- [x] Add a safe in-app DotClk scene-library downloader with progress, cancellation,
      atomic installation, AppData storage, automatic selection, and rescanning

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Display

- [x] Optional Windows x64 screensaver (`.scr`) using the same clock, animations, and settings

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Technology

- [x] C# with .NET 10 LTS and Avalonia UI for Windows and Raspberry Pi

### Replace selected local repositories with fresh clones. / Completed work / Ideas for later versions — Future — Serum, full color, and larger DMDs

- [x] Windows screensaver mode

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 3 — basic controls and saved settings

- [x] Save automatic cycle, intervals, animation count, and random/sequential mode in AppData
- [x] Save animation directory, playback mode, interval, color, and brightness in AppData

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 5 — first distributable Windows build

- [x] Complete the README
- [x] Create a self-contained `win-x64` build
- [x] Verify that the previous build is archived before every new build
- [x] Run a complete SCN compatibility scan and store its report with the build
- [x] Create a portable ZIP
- [x] Create standalone single-file Windows `.exe` and `.scr` builds

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone binary generation

- [x] Publish one standalone `DmdClock.App.exe`
- [x] Copy the verified standalone executable to `DMDClock.scr`

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone packaging

- [x] Extend `scripts/Build.ps1` to create `output/current/win-x64-standalone`
- [x] Include `DmdClock.App.exe`, `DMDClock.scr`, external `i18n`, `README.md`, `build-info.json`, and `SHA256SUMS.txt`

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone publishing profile

- [x] Publish self-contained for `win-x64` with `PublishSingleFile=true`
- [x] Keep trimming disabled initially and document the Avalonia reflection constraint

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone writable-data handling

- [x] Verify settings and library indexes are stored under `%LOCALAPPDATA%\DmdClock`

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 2. Basic Windows application

- [x] Create a .NET 10 project targeting Windows x64
- [x] Create a regular `.sln` and clearly organized `.csproj` projects
- [x] Create a main window with a 4:1 aspect ratio
- [x] Implement the first DMD renderer using separated round dots
- [x] Add a thin black border around the display
- [x] Implement the complete context menu in the display
- [x] Add an open-directory dialog
- [x] Add start, stop, next, and previous animation
- [x] Display clear error messages for damaged or unknown files

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 4. Settings

- [x] Save implemented settings under the user's AppData directory

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 5. Distribution

- [x] Close related DMDClock processes before building and start the new Windows build after successful publication
- [x] Publish the current Windows x64 distribution

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 6. README and documentation

- [x] Show how to build for Windows x64

### Replace selected local repositories with fresh clones. / Manual Windows test checklist

- [x] Skip SmartScreen and antivirus release testing; paid signing, reputation,
      and third-party scanning services are not justified for this hobby project
- [x] Repeat standalone tests on clean Windows 10 and Windows 11 x64 machines
      without an installed .NET runtime

## macOS

### DMDClock for Windows x64 — development TODO / Priority 0 — unified scene-library downloads on every platform / P0.2 — Windows and macOS download selector

- [x] Rename **Download DotClk scenes…** to **Download scenes…** in the shared
      Avalonia menu used by Windows and macOS.
- [x] Add a two-library selection dialog driven by the shared catalog, with
      DMD-Large recommended and the inclusion relationship clearly
      stated before download.
- [x] Reuse the existing progress, cancellation, size/SHA validation, safe ZIP
      extraction, atomic installation, library selection, and rescan workflow for
      either selected pack.
- [x] Store the two packs in distinct managed library directories and prevent a
      second installation from creating duplicate or ambiguous library entries.

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 6 — macOS Apple Silicon application

- [x] Prove that the current Avalonia application cross-publishes for
      `osx-arm64` with the required native Avalonia and Skia libraries.
- [x] Add a repeatable `scripts/Build-MacOS.ps1` workflow that produces a
      versioned `DMDClock.app` bundle and ZIP without changing the Windows build.
- [x] Add bundle metadata, stable identifier `io.github.drwize.dmdclock`, and a
      temporary PNG icon resource; replace it with a generated `.icns` set on a
      Mac before public release.
- [x] Add a `macos-14` CI build that verifies Mach-O architectures,
      bundle structure, executable permissions, and package contents.
- [x] Publish an unsigned macOS DMG developer preview with its own build metadata
      and SHA-256 checksums; keep it separate from Windows artifacts.

## ESP32-S3

### v1.6.0 provisioning and documentation closure

- [x] Validate required PowerShell commands, writable staging and log locations,
      free disk space, and network access before downloads or hardware mutation.
- [x] Keep requirements checks, downloads, and normal staging available without
      administrator rights; require elevation only when a selected Windows
      operation genuinely needs it.
- [x] Document requirements checks, download-only staging, dry-run behavior,
      offline SD preparation, and verified release flashing in the end-user guides.

### DMDClock ESP32-S3 roadmap / Remaining safety and shared-data work / P0 — repository and recovery safety

- [x] Stabilize the Windows colour/menu baseline.
- [x] Keep ESP32 work on scoped feature branches.
- [x] Confirm the exact physical board and module revision.
- [x] Archive the vendor factory image.
- [x] Record the USB connector, driver, COM port, flash command, and reset/
      boot-button sequence.

### DMDClock ESP32-S3 roadmap / Required resources / Hardware on the desk

- [x] Waveshare `ESP32-S3-Touch-LCD-7`, physically confirmed as 800×480.
- [x] Module confirmed as `ESP32-S3-WROOM-1-N16R8`.
- [x] Data-capable USB cable connected to the port labeled `UART` for initial
      flashing and serial logs.
- [x] Stable 5 V USB power.
- [x] Reliable TF/microSD card prepared as FAT32.
- [x] A local folder containing the vendor schematic, current example source,
      factory binary, and recovery notes.

### DMDClock ESP32-S3 roadmap / Required resources / Software on the workstation

- [x] Git.
- [x] Workspace-local .NET 10 for Windows tests and code generation.
- [x] Sufficient CPU and RAM for local parallel builds.
- [x] Pinned ESP-IDF 5.5.2 checkout and tools beneath
      `E:\ai\.tools\esp-idf`.
- [x] ESP-IDF-managed Python environment.
- [x] ESP-IDF-compatible CMake, Ninja, Xtensa compiler, and esptool.
- [x] Current official Waveshare example archive saved locally with SHA-256
      `5351D443EAA605CAB1EB80D050D867C18E1CE2B33C9CBC78AAE1B7BCA040B038`.

### DMDClock ESP32-S3 roadmap / Version 1.6 target — fonts and orientation / Fixed 0°/180° and 3.49B automatic orientation

- [x] Persist `fixedRotation` (`0` or `180`) and `orientationMode` (`fixed` or
      `auto`), defaulting the physical 3.49B V2 to automatic and other targets to
      fixed 0° while retaining the last fixed choice.
- [x] Add a direct `POST /api/orientation`, report requested/effective orientation
      and sensor availability through `/api/state`, and document the contract in
      `/api-docs`. Reject invalid angles and `auto` on unsupported boards.
- [x] Add immediate **Fixed 0°** and **Fixed 180°** controls to the web
      section. Offer **Automatic** only when QMI8658 availability is reported.
- [x] Rotate the completed logical composition, including overlays and setup/QR
      screens, then apply each board's existing physical transfer. Apply the same
      180° transform to touch coordinates before hit testing.
- [x] For Waveshare 3.49B V2 only, probe QMI8658 at `0x6b` on the existing shared
      I2C0 bus (SDA GPIO47, SCL GPIO48), use low-rate accelerometer/gravity samples
      rather than the gyroscope, and use the physically observed signed Y axis.
- [x] Filter samples and require separate 0.60 g enter / 0.35 g exit thresholds
      plus an 800 ms dwell time. Retain the last stable result when ambiguous; on
      probe/read failure expose diagnostics and fall back to the persisted fixed
      orientation without blocking boot.
- [x] Fixed 180° is built and captured nonblank in `Waveshare7` and `Landscape349`
      QEMU. Physical 3.49B V2 validation confirms positive Y as 0°, negative Y as
      180°, correct orientation before the first visible boot frame, repeated
      automatic turns, rotated touch, persistence, and zero QMI8658 read errors.
      Physical Waveshare 7 validation confirms fixed 0°/180°, rotated controls and
      touch, and that Automatic is unavailable.

### DMDClock ESP32-S3 roadmap / Version 1.6 target — fonts and orientation / Shared DotClk font parity

- [x] Use the Windows/macOS inventory as the reference: built-in 5×7 plus embedded
      ALTERN8, FISHY, TREK, and TWILIGHT. Inter remains a desktop TTF in v1.6;
      arbitrary ESP32 TTF/OTF support remains the later measured project.
- [x] Build a deterministic `.fnt`-to-C generator that preserves version-1 glyph
      metrics, kerning, four-bit atlas intensities, masks, and canonical hashes.
- [x] Implement one board-independent ESP32 font renderer and selector on the
      logical 128×32 framebuffer. Do not duplicate fonts or rendering in the
      Waveshare 7 and 3.49B panel drivers.
- [x] Persist the selected clock font and expose it through settings, `/api/state`,
      the web remote, the TF-card settings mirror, and `/api-docs`.
- [x] Keep a separate date-font setting deferred until the planned ESP32 date
      renderer exists; it is not part of the completed clock-font gate.
- [x] Preserve the internal 5×7 fallback for missing, invalid, or unavailable font
      assets and verify time, scene clock overlays, separators, masks, glow, and
      missing glyphs with golden framebuffer fixtures.
- [x] Pass both QEMU profiles and both physical-board matrices, including render
      timing, heap/PSRAM, restart persistence, and web/touch responsiveness. Both
      QEMU profiles pass all five selections with distinct framebuffer hashes;
      the 3.49B V2 physical matrix also passes all five visual selections, time
      format combinations, frame advancement, scene playback, memory, clean
      touch/settings diagnostics, and reboot persistence. The Waveshare 7 passes
      the equivalent physical matrix. The final closure evidence has 22 exact C
      intensity-plus-mask desktop goldens, 176 passing .NET tests, 19 QEMU captures
      per model including glow/hot-core changes, and final-image physical reboots
      123 to 124 on Waveshare 7 and 31 to 32 on 3.49B V2.

### DMDClock for Windows x64 — development TODO / Current baseline / Repository integration and cleanup — reviewed 2026-08-12

- [x] For the next release, make **DMD-Large** the preferred/default scene library
      on Windows, macOS, and ESP32 while keeping **Original DotCLK-Orig** as an
      explicit selectable alternative; update the shared and bundled catalogs,
      UI labels, tests, screenshots, and release validation together.
- [x] Preserve and separate the uncommitted work in `qemu-sd-settings-debug`;
      it now has its own retained worktree and was not combined with the release.
- [x] Confirm the version 1.4.1 Windows EXE/SCR, installer, macOS ARM64 package,
      ESP32 package, manifests, and checksums all reference the integrated commit.
- [x] Show a non-blocking latest-release notice in the normal Windows startup and
      ESP32 web remote; never auto-download or auto-install an update.
- [x] Add separate beginner workflows for Windows and ESP32 plus SD-card setup.
- [x] Default the complete ESP32 web/API server to LAN-only source addresses and
      expose the persistent switch in the remote.
- [x] Recover a stale TF-card SPI state with three bounded enable/settle mount
      attempts; verify the live card remounts and all 2,324 scenes return.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P0 — desktop-compatible ESP32 DotClk font pipeline — complete 2026-08-14

- [x] Keep the desktop font inventory as the reference: Windows and macOS use the
      same built-in 5×7 fallback, embedded ALTERN8, FISHY, TREK, and TWILIGHT
      DotClk fonts, and external bundled Inter TTF.
- [x] Port the four DotClk fonts once in the shared ESP32 firmware, not separately
      in the Waveshare 7 and 3.49B panel backends. Generate deterministic compact
      C assets from the canonical `.fnt` files, preserving glyph widths, kerning,
      four-bit intensities, masks, source hashes, and the built-in 5×7 fallback.
- [x] Add a board-independent bitmap-font renderer for the logical 128×32 DMD and
      use the same selected font before either physical panel scales the completed
      framebuffer to 6× or 5×.
- [x] Match the existing desktop pipeline rather than designing a new visual
      interpretation: embedded resource IDs, variable glyph widths, kerning,
      four-bit intensities, overlap masks, centring, clipping, and generated
      fallback separators must produce the same logical 128×32 result.
- [x] Add persisted clock-font selection to the ESP32 settings, state API, TF-card
      settings mirror, web remote, and API documentation.
- [x] Keep independent date-font selection outside this clock-font P0; add it with
      the separately planned ESP32 date renderer rather than creating a dormant
      setting now.
- [x] Keep Inter and arbitrary TTF/OTF rasterization outside the v1.6 embedded
      parity gate. Inter remains bundled for the desktop applications; any ESP32
      use must go through the separately measured bitmap-conversion project rather
      than adding an outline-font engine to the display task.
- [x] Add converter freshness/hash tests, malformed/generated-asset tests, golden
      128×32 framebuffer fixtures, persistence tests, and web/API tests for every
      font and fallback path. Converter, malformed-input, canonical golden-hash,
      API round-trip, unknown-font rejection, and distinct QEMU framebuffer checks
      pass. The actual C renderer matches 22 desktop intensity-plus-mask goldens,
      including built-in scaling, 12-hour AM/PM, clipping, separators, overlap
      masks, unknown font IDs, and missing glyphs. Physical restart persistence
      passes on both supported boards; QEMU cannot run that gate because its
      network adapter cannot recover after `esp_restart()`.
- [x] Validate all five choices in `Waveshare7` and `Landscape349` QEMU, then on
      both physical boards. Confirm 12/24-hour time, optional seconds, missing
      glyph fallback, masks, glow, scene clock overlays, frame time, heap/PSRAM,
      touch responsiveness, and restart persistence. Both QEMU profiles pass all
      five font selections with five distinct framebuffer hashes. The final QEMU
      closure matrix records 19 captures per model, including changed framebuffer
      hashes for glow and hot-core rendering, static/animated scene playback, and
      touch diagnostics.
- [x] Complete the Waveshare 3.49B V2 physical font matrix: all five fonts were
      visually confirmed, 12/24-hour and seconds combinations rendered while the
      physical frame counter advanced, scene playback remained healthy, touch had
      zero read errors, NVS/TF saves stayed `ESP_OK`, heap/PSRAM stayed healthy,
      and TWILIGHT persisted across the final-image reboot from boot count 31 to
      32. The corrected built-in 12-hour AM/PM layout was visually confirmed.
- [x] Complete the Waveshare 7 physical font matrix: all five fonts were visually
      confirmed, the same time/seconds, frame, scene, memory, touch, and settings
      checks passed, and TWILIGHT persisted across the final-image reboot from
      boot count 123 to 124. The corrected built-in 12-hour AM/PM layout was
      visually confirmed.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P1 — 0°/180° orientation and 3.49B QMI8658 positioning

- [x] Define one shared persisted orientation contract with `fixedRotation`
      restricted to `0` or `180` and `orientationMode` restricted to `fixed` or
      `auto`. Default the physical 3.49B V2 to automatic, default Waveshare 7 and
      QEMU to fixed 0°, and retain the last explicit fixed rotation.
- [x] Add a direct `POST /api/orientation` endpoint accepting only the two exact
      rotations and the supported mode, return effective/requested orientation in
      `/api/state`, and document errors for invalid values or `auto` on a board
      without an orientation sensor.
- [x] Add a compact **Screen orientation** control to the web remote with immediate
      **Fixed 0°** and **Fixed 180°** choices. Enable **Automatic** only when the
      state API reports a usable QMI8658; do not imply that the Waveshare 7 has an
      accelerometer.
- [x] Apply 180° after composing the logical DMD/overlay so scenes, clock, metadata,
      startup/setup screens, QR codes, and touch controls rotate together. Invert
      both touch axes against the board's logical width and height so hit targets
      remain attached to the visible controls.
- [x] On the 3.49B V2, add a board-local QMI8658 accelerometer driver at I2C
      address `0x6b` on SDA GPIO47/SCL GPIO48, sharing I2C0 with the TCA9554
      expander. Use acceleration/gravity only; keep the gyroscope disabled.
- [x] Physically identify sensor Y as the signed axis distinguishing the two
      landscape positions. Use filtered samples, an ambiguity threshold,
      and a dwell time before changing orientation so vibration or a nearly flat
      device cannot repeatedly flip the screen.
- [x] Keep the last stable orientation through ambiguous samples. If QMI8658 probe,
      or reads fail, report diagnostics and fall back to the persisted fixed
      rotation without delaying boot or affecting display/touch operation.
- [x] Fixed 180° is built and nonblank in both QEMU profiles, and the direct API
      rejects unsupported automatic mode. Physical 3.49B V2 validation confirms
      both automatic positions, boot-time orientation, rotated touch, filtering,
      persistence, and zero sensor errors. Physical Waveshare 7 validation confirms
      fixed 0°/180°, rotated controls/touch, and no Automatic option. QEMU is not
      sensor proof.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.1 — audit before implementation

- [x] Read both entry scripts and every script, manifest, catalog, package, tool,
      and documentation path they invoke. Map the current control flow before
      editing it.
- [x] Inventory every destructive operation, disk-number/drive-letter assumption,
      COM-port assumption, network dependency, external tool/version dependency,
      elevation requirement, shared dependency between the scripts, and path that
      could select the wrong disk, board revision, firmware, or serial device.
- [x] Briefly document current risks and the proposed parameter/staging design
      before implementation. Prefer safety over backward compatibility wherever
      the existing behavior could cause data loss or flash incompatible firmware.
      The audit and staged contract are recorded in
      `docs/development/esp32/POWERSHELL-PROVISIONING.md`.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.2 — shared requirements gate

- [x] Add a non-mutating `-CheckRequirements` path that validates Windows 11,
      64-bit Windows/x64, PowerShell 7 or newer, and that the host is actually
      `pwsh` rather than Windows PowerShell 5.1.
- [x] Check internet access and working GitHub TLS/HTTPS only for operations that
      require a download. Offline operations using a complete local staging folder
      must not fail merely because the network is unavailable.
- [x] On failure, stop before mutation and report the failed check, detected value,
      required value, and a concrete manual remediation. Do not automatically
      install PowerShell, drivers, Python, esptool, or any system component.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.3 — download and staging without attached hardware

- [x] Add a `-DownloadOnly -Destination <path>` workflow with a documented local
      structure such as `DmdClockFiles\ESP32`, `SDCard`, `Tools`, and `Logs`.
      Identify and stage everything later required by both supported ESP32 board
      variants and the selected SD-card scene-library workflow.
- [x] Guarantee that download-only mode never enumerates or requires an SD card or
      ESP32, never writes removable media, and never invokes a format, partition,
      erase, or flash command.
- [x] Validate HTTP success, non-zero content, expected size when known, and
      SHA-256 wherever practical. Show whether each artifact was downloaded,
      reused, or replaced; never silently trust a stale cached file.
- [x] Download to a temporary file in the destination directory, verify it, then
      atomically promote it to the final name. Remove incomplete temporary files
      on failure and abort safely when GitHub or another required source cannot be
      reached.
- [x] Produce a final inventory containing source URL, local path, size, SHA-256,
      version/target, and status for every staged firmware, SD payload, and tool.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.4 — complete offline consumption

- [x] Add `-Source <staging-path>` support so SD preparation can run without new
      network access when the staging inventory is complete and verified.
- [x] Provide the equivalent offline firmware/tool consumption path for ESP32
      flashing where technically possible.
- [x] Validate the complete staged manifest before touching an SD card or ESP32.
      If anything is missing, corrupt, stale, or for the wrong board/revision,
      report the exact artifacts and stop before the destructive phase.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.5 — physical SD-disk safety

- [x] Never automatically select the first USB/removable disk. Enumerate plausible
      physical candidates with disk number, drive letter, model, size, bus type,
      partitions, volume label, and filesystem, and require an explicit physical
      disk selection.
- [x] Exclude the Windows system/boot disk and internal disks as far as Windows can
      reliably identify them. Never select or format a disk from drive letter
      alone, and never choose automatically when multiple candidates exist.
- [x] Do not implement partitioning, formatting, or deletion of card content.
      Require the selected disk to expose exactly one mounted, healthy FAT32
      volume; otherwise stop with manual remediation instructions.
- [x] Display the selected physical disk and FAT32 volume unambiguously, then
      re-enumerate and verify the same disk identity, layout, size, and topology
      immediately before copying. Abort if anything changed.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.6 — guarded ESP32 flashing

- [x] Verify the staged firmware, manifest, checksums, flash tool, and tool version
      before opening or changing a serial device.
- [x] Enumerate plausible COM devices with useful Windows device information.
      Never use an arbitrary port; require selection when multiple candidates are
      present and fail clearly when none are present.
- [x] Query chip information before flashing when supported. Show the selected COM
      port, detected ESP32 chip, flash size, board target/revision, firmware file,
      firmware version, size, and SHA-256 before confirmation.
- [x] Preserve the incompatible 3.49B V1/V2 guard and supported Waveshare 7 versus
      7B distinction. Revalidate the selected device immediately before flashing
      and retain the final exact `FLASH` confirmation.

### DMDClock for Windows x64 — development TODO / Current baseline / Version 1.6 roadmap — ESP32 font parity and screen orientation / P2 — safe staged PowerShell provisioning — v1.6 release blocker / P2.7 — dry-run, errors, and per-run evidence

- [x] Provide consistent `-WhatIf` or `-DryRun` behavior for requirements,
      download, SD, and flash modes. Show files, destinations, physical disk,
      copies, commands, COM device, and firmware without changing files, media, or
      hardware.
- [x] Use `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, and
      deliberate `try/catch/finally` handling. Critical failures must stop the
      workflow, preserve the original error context, clean partial artifacts where
      safe, and never fall through into a destructive step. Avoid empty catches or
      suppression of relevant errors.
- [x] Write one non-secret log per run containing timestamps, PowerShell/Windows
      versions, architecture, checks, URLs, destinations, hashes, selected disk or
      COM port, external tool versions, planned/executed commands, outcome, and
      errors. Keep secrets, Wi-Fi credentials, tokens, and passwords out of logs.

### DMDClock for Windows x64 — development TODO / Priority 0 — unified scene-library downloads on every platform / P0.3 — Windows-prepared ESP32 TF card

- [x] Extend `Prepare-DmdClockSdCard.ps1` with explicit `Original` and `DmdLarge`
      choices backed by the shared catalog, exact archive size/SHA-256 checks,
      exact scene counts, SCN validation, and a verified local cache.
- [x] Keep preparation idempotent: matching cards produce zero writes, damaged
      managed files are repaired, and switching libraries preserves obsolete
      previously managed scenes as well as unrelated/custom card content.
- [x] Remove full-library download controls from the ESP32 web remote and replace
      them with read-only installed-library status plus a link to the Windows
      TF-card preparation article. Keep the existing API path only as an internal
      compatibility surface for firmware 1.4.0.

### DMDClock for Windows x64 — development TODO / Priority 0 — unified scene-library downloads on every platform / P0.4 — tests and release acceptance

- [x] Benchmark one ZIP download plus on-device extraction against sequential
      single-file downloads for the same ESP32 scene library. Run the ZIP path in
      QEMU, retain timestamped phase logs, and record elapsed time, transferred
      bytes, HTTPS request count, scene count, and output equivalence before
      choosing the production delivery method. The 2026-08-11 Original-pack test
      found one ZIP was 75.71x faster and transferred 9.08x fewer payload bytes
      than 2,324 sequential requests in the controlled host comparison; the
      actual QEMU ZIP installation completed in 613.925 seconds. Keep ZIP delivery;
      see `docs/development/reports/SCENE-PACK-DELIVERY-BENCHMARK.md`.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 0 — Baseline and safety

- [x] Confirm the product is the 800×480 `7`, not the 1024×600 `7B`.
- [x] Download and archive the exact factory firmware and Waveshare example used
      for board initialization.
- [x] Record the UART connector, CH343 COM4 port, and explicit flash procedure.
- [x] Establish the fixed 800×480 N16R8 production target.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 2 — Board bring-up

- [x] Create the ESP-IDF project from the official Waveshare board example.
- [x] Pin RGB timing, LCD GPIO mapping, CH422G backlight control, GT911 touch
      configuration, and PSRAM for the original 800×480 board.
- [x] Verify GT911 orientation and add TF-card pin handling on the
      physical board.
- [x] Read touch points and validate orientation on the live overlay.
- [x] Mount and read/write the prepared FAT32 TF card.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 3 — DMD renderer

- [x] Implement the packed 128×32 four-bit framebuffer.
- [x] Draw separated round dots at exact 6× scale.
- [x] Implement brightness and the lightweight configurable glow.
- [x] Use double-buffered frame-boundary swaps for the production RGB panel.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 4 — Fixed Basic colors

- [x] Implement the fixed Basic renderer, brightness, and black background.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 5 — Clock, date, and settings

- [x] Implement time formatting, optional seconds, 12/24-hour display, and
      persisted timezone selection.
- [x] Add Wi-Fi provisioning, manual sync, timezone, and daylight-saving
      behaviour.
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
- [x] Migrate existing NVS settings into the editable SD settings backup and
      prefer valid SD settings at boot.
- [x] Preserve the running clock across temporary network or NTP loss.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 6 — SCN and TF-card playback

- [x] Port the bounds-checked SCN parser and validate every frame/storyboard
      boundary before decoding.
- [x] Reuse an 11-scene compatibility corpus in QEMU.
- [x] Implement first/regular/final storyboard timing, masks, blanking, clock
      layers, one-shot completion, and Windows-style clock/scene cycling for the
      QEMU corpus and SD library.
- [x] Resolve the ESP32 scene catalog from the same schema-1
      `scene-metadata.json` used by Windows, including exact-file and
      longest-prefix rules, while leaving timing and masks in the SCN.
- [x] Scan the complete flat TF-card scene directory into a compact PSRAM index.
- [x] Add sequential/random playback and automatic clock/animation cycles for
      the QEMU corpus and SD library.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 7 — Touch and local web settings

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
- [x] Reproduce colour-family swatches and current-selection summaries.
- [x] Add scene, clock, brightness, colour, network, schedule, and NTP settings.
- [x] Provide `Sync NTP` with non-blocking status and last-sync age.
- [x] Publish a compact diagnostics footer and `/api/state` values for chip
      temperature, Wi-Fi, memory, SD, time, reset, rendering, touch, settings,
      screen state, build, and uptime.
- [x] Label internal temperature as chip-only and not ambient.
- [x] Keep HTTP request handling outside the display render loop.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 7b — Home Assistant

- [x] Add optional local MQTT broker configuration, disabled by default, with
      credentials mirrored in NVS and the explicitly plaintext SD backup.
- [x] Publish Home Assistant MQTT discovery and birth/LWT availability.
- [x] Add the first display, brightness, scene-navigation, NTP, playback, system,
      storage, Wi-Fi, time, and firmware entities.
- [x] Validate bounded commands, publish state at a low rate/on change, and keep
      MQTT work off the display task.
- [x] Add a credential-free on-screen QR for the current local setup URL; state
      clearly that Home Assistant MQTT discovery does not use QR pairing.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 7c — Gradient, Raster, and Plasma

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

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 7d — Hot-core glow

- [x] Add shared optional Hot-core settings with Classic warm centre, Follow theme,
      and Dual colour modes.
- [x] Implement the precomputed ESP32 three-ring/LUT renderer and retain the
      current lightweight glow as its measured fallback.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Delivery phases / Phase 9 — Packaging and release

- [x] Produce a USB release ZIP with bootloader, partition table, and application
      images for full or application-only flashing.
- [x] Produce a target-specific manifest, flash offsets, build metadata, and
      SHA-256 checksums.
- [x] Provide one PowerShell installer/updater that selects a compatible GitHub
      release, verifies it, and optionally flashes an explicit COM port.
- [x] Keep Windows and ESP32 artifacts separate while allowing the GitHub release
      publisher to validate and include both with `-IncludeEsp32`.

### Produce the USB install/update ZIP, manifest, and checksum artifacts. / Web authentication

- [x] Default to LAN-only HTTP access and enforce it at socket acceptance so the
      remote, API documentation, and every API route share the same boundary.
- [x] Persist the LAN-only switch in NVS and the editable SD settings backup.
- [x] State clearly that the filter is not authentication: private-LAN clients
      remain trusted and HTTP traffic is unencrypted.

### Replace selected local repositories with fresh clones. / Active roadmap / Hot-core glow — Windows and ESP32-S3 implemented

- [x] Add the optional Windows Hot-core style with persistent Classic amber,
      Follow theme, and Dual colour modes.
- [x] Capture real Windows clock comparisons for all three Hot-core colour modes
      and document the controls in the settings guide.
- [x] Port the accepted Hot-core style to ESP32-S3 with persistent web/API, NVS,
      and SD-card settings while retaining the selected theme for body and halo.
- [x] Render three controlled Windows layers: a small warm or selected core, the
      saturated dot body, and a soft colour-matched halo that ends before the
      midpoint between neighbouring dots.
- [x] Keep Windows core opacity and radius monotonic across all 16 intensity levels;
      dim dots do not receive the same core as fully lit dots.
- [x] Cache Windows radial-gradient dot, halo, and core brushes by palette and
      intensity instead of rebuilding them per dot or frame.
- [x] Use a precomputed three-ring kernel or small lookup table on ESP32-S3; avoid
      per-pixel square roots and retain the existing lightweight glow as fallback.

### Replace selected local repositories with fresh clones. / Backlog after the active priorities / ESP32-S3 web management

- [x] Build the first host-verified ESP32-S3 firmware slice with the 800×480 RGB
      panel, exact 6× DMD, brightness, clock, 11 embedded test scenes, persistent
      settings, recovery access point, and embedded web remote
- [x] Document that ESP32-S3 Wi-Fi is **2.4 GHz (802.11 b/g/n) only**; it cannot
      connect to a 5 GHz-only SSID, so provisioning must use a 2.4 GHz network
- [x] For a first flash with home Wi-Fi preconfigured, run
      `.\scripts\esp32\Set-DmdClockBootstrapWifi.ps1 -WifiSsid 'My Wi-Fi' -Build`,
      enter the Wi-Fi password only at its masked prompt, and flash the explicit
      COM port. After confirming the connection, run
      `.\scripts\esp32\Clear-DmdClockBootstrapWifi.ps1 -Build` and reflash
      without erasing NVS so the saved credentials remain on the device but are
      removed from the application image. Never record real credentials here or
      in another tracked file.
- [x] Show a dedicated network startup screen for 20 seconds with the configured
      Wi-Fi name and `IP` with the assigned DHCP address or a
      connecting/not-configured state. Show the setup IP only until a DHCP lease
      exists; never show the Wi-Fi password.
- [x] Show the running ESP-IDF application build and monotonic uptime as
      `days hh:mm:ss` at the bottom of the device web remote.
- [x] Expose GT911 touch diagnostics through `/api/state`: detected state,
      raw-event count, last coordinates/status byte, interrupt level, and I2C
      read errors.
- [x] Match Espressif's GT911 status handshake by acknowledging the status
      register even when the data-ready bit is clear, preventing a low interrupt
      from remaining stuck between samples.
- [x] Provide a guided 25-second physical touch test across five visible targets
      with a per-target countdown, live event count and last coordinates,
      followed by a five-second result; start it explicitly from the webpage
      instead of delaying every boot.
- [x] Remove redundant `PINBALL` and `SCENE` prefixes from display metadata;
      show the game, scene title, year, and manufacturer directly.
- [x] Compact scene metadata to one fitted
      `game - scene - year - manufacturer` row and add persistent information
      colours for discreet grey, follow-theme, or a standalone custom colour.
- [x] Mirror all web-editable settings to the human-readable SD file
      `/dmd/config/settings.json`, load it over NVS at boot, migrate existing
      NVS settings on first boot, and use atomic temporary-file replacement.
- [x] Apply the 24-hour-clock and show-seconds switches immediately, matching
      information-colour and theme controls.
- [x] Apply the Scene information switch immediately when it changes on the web
      remote, without requiring the separate Save changes button.
- [x] Serve an embedded `/api-docs` subpage linked from the web remote with every
      local HTTP endpoint, accepted setting, control action, example, and
      local-network security limitation, plus a copy control for each example.
- [x] Add a confirmed Reboot device button to the web remote and a delayed
      `reboot` action to `POST /api/action`, allowing the HTTP response to
      complete before the ESP32 restarts.
- [x] Add Home Assistant-ready diagnostics to `/api/state` and a compact web
      footer: approximate chip temperature, RSSI, heap/PSRAM, SD capacity,
      settings-file health, flash/CPU, boot/reset data, render counts, NTP, and
      touch health.
- [x] Show the effective physical screen state in the diagnostics footer,
      distinguishing On, the manual Screen switch, the weekly schedule, and a
      temporary touch-wake override.
- [x] Add all eight Basic, eight Gradient, and sixteen Raster themes with the same
      stable preset IDs used by Windows
- [x] Add a persistent Custom choice to all four ESP32 colour families: one
      Basic colour, two Gradient colours, four Raster bands, and the existing
      four-stop Plasma palette, with matching API controls and web previews
- [x] Port the frozen 256-step integer Plasma field, phase calculation, 128-colour
      cyclic interpolation, and the four existing Windows reference vectors
- [x] Add all eight Plasma presets plus Custom, persistent 1–60 second cycle
      timing, custom RGB stops, API state/settings, animated web preview, and
      Plasma selection through the shared colour controls
- [x] Schedule Plasma independently at a maximum of 30 FPS while preserving SCN
      intensity, masks, clock layers, glow, web, touch, and NTP responsiveness
- [x] Add a lightweight per-dot glow halo with persistent 0–100% strength,
      matching transient touchscreen/web toggles, and a web strength slider
- [x] Add the optional **Hot-core glow** dot style on ESP32-S3 using a bright
      centre, a colour-matched halo, and a black one-pixel cell boundary
- [x] Show the full device-local timestamp, browser clock difference, time source,
      NTP progress, configured servers, and successful synchronization state in
      the web remote
- [x] Show the exact last NTP synchronization time and elapsed age in the web
      remote; show `NTP OK` plus the elapsed age on the physical NTP button after
      a successful check.
- [x] Add automatic NTP through `pool.ntp.org` and `time.cloudflare.com`, a manual
      NTP action, and browser-time fallback
- [x] Match the Windows scene-session behavior for first-frame timing, regular
      frames, masks, blank first/last steps, clock layers, final holds, one-shot
      return to clock, sequential/random order, scenes per cycle, and scene gaps
- [x] Make the physical and web `Colour` action advance
      Basic → Gradient → Raster → Plasma and make `Next theme` advance only
      within the selected family (including Plasma palettes).
- [x] Add top-row `Next pinball` and `Next scene` controls; the first advances
      to another metadata game and the second advances within the current game.
      Keep information, glow, NTP, return-to-clock, and touch-test web actions.
- [x] Add the original board's GT911 touch implementation using GPIO4,
      GPIO8/GPIO9, and CH422G EXIO1, while allowing non-touch boards to boot
- [x] Keep the on-screen touch buttons visible for eight seconds after
      interaction, fade them out, and use the first touch only to reveal fully
      hidden controls
- [x] Verify GT911 detection, coordinate orientation, debounce, guided-test
      reporting, and live overlay actions on the physical 800×480 board
- [x] Replace the five equal bottom touch targets with a two-row overlay:
      two wide top buttons for `Next pinball` and `Next scene`, plus bottom
      controls for colour family, next theme, information, glow, and NTP.
      Keep the first hidden-screen tap reveal-only.
- [x] Remove `CONFIG_LCD_RGB_RESTART_IN_VSYNC`: in ESP-IDF 5.5.2 it restarts
      RGB DMA at every VSYNC and made the physical flicker worse; Waveshare
      leaves it disabled.
- [x] Recheck physical flicker with double-buffered frame-boundary swaps and
      normal continuous DMA at the Waveshare 16 MHz baseline. The current
      820×500 total timing produces approximately 39.0 Hz and is visually stable
      on the connected board.
- [x] Define a single `/dmd` TF-card root for scenes, fonts, Plasma assets,
      extended web assets, exported configuration, backups, bounded logs,
      rebuildable caches, and verified downloads
- [x] Add non-fatal SPI TF mounting on GPIO11/12/13 with CH422G EXIO4 enable,
      create the `/dmd` content root, scan the complete flat SCN directory into
      PSRAM,
      embed no production SCN files, and remain in clock-only mode when storage
      has no valid scenes
- [x] Remove the production 11-scene filename allowlist, widen scene IDs to
      16 bits, and verify all 2,324 prepared SCNs appear in the live ESP32 API
      and web scene catalog. Keep the deterministic 11-scene QEMU projection.
- [x] Add optional bounded SD playback logging at
      `/dmd/logs/playback.log`: record timestamped SCN/game/title and colour
      family/subtheme events, expose its path/size/state in the API and webpage,
      cap it at 256 KB, and keep one rotated previous log.
- [x] Make Windows and ESP32 resolve scene titles, games, manufacturers, years,
      prefix rules, and exact overrides from the same schema-1
      `scene-metadata.json`; keep SCN storyboard timing authoritative
- [x] Keep the 243 KB shared metadata catalog on TF storage in production,
      embed an automatically generated 11-scene projection in QEMU for
      deterministic tests, and release its parsed JSON tree after the ESP32
      scene records have been resolved
- [x] Verify FAT32 mounting, PSRAM loading of all 2,324 scenes, shared metadata,
      settings backup, playback log, and `/dmd` directory creation on the
      physical board and 64 GB card.
- [x] Publish the complete 2,416-scene cross-platform pack and expose its HTTPS
      URL, exact byte size, SHA-256, scene count, and ESP32-S3 compatibility in
      the shared schema-1 scene catalog.
- [x] Add an ESP32 background scene-library job with `Install`, `Update`, `Repair`,
      progress/status APIs, cancellation, a single-operation lock, and clear
      browser feedback that never blocks the display or HTTP server task.
- [x] Download the shared catalog and selected archive over certificate-verified
      HTTPS into TF-card staging, support restart-safe resume, enforce archive and
      free-space limits, and verify the exact catalog byte size and SHA-256.
- [x] Extract the versioned ZIP into a separate flat staged scene directory,
      reject unsafe paths and unsupported entries, validate every SCN plus shared
      metadata/content manifests, and require the catalog scene count.
- [x] Preserve unrelated user-uploaded scenes, retain the last usable snapshot,
      atomically activate only a fully validated staged set, recover interrupted
      activation on boot, rebuild the scene index, and remove obsolete staging.
- [x] Add one-click complete-pack `Install`, `Update`, `Repair`, and `Cancel`
      controls plus live progress and reboot-required feedback to the ESP32 web
      interface.
- [x] Run the published complete ZIP through both writable-SD QEMU profiles:
      Waveshare7 800x480 and Landscape349 640x172 each downloaded, verified,
      extracted, activated, rebooted, and indexed all 2,416 scenes.
- [x] Label the built-in ESP32-S3 temperature explicitly as **Chip temperature
      (approximate)**; never present it as room/ambient temperature
- [x] Add the first optional Home Assistant track through local MQTT discovery,
      birth/LWT availability, and broker credentials mirrored in NVS and the SD
      settings backup; keep it disabled by default
- [x] Add a credential-free on-screen QR shortcut to the current local device
      web address; MQTT discovery itself does not use QR pairing
- [x] Expose the initial display power, brightness, next pinball, next scene,
      NTP sync, current scene, firmware, uptime, RSSI, approximate chip
      temperature, heap, SD free/present, and time-sync entities

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 1 — play a selected SCN file

- [x] Implement storyboard first/last steps, blanking, transparency masks, and clock layers according to the original firmware

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / Current baseline

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
- [x] Publish the validated board-specific DMDClock firmware image in v1.5.0.

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P0 — freeze the display contract

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

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P1 — QEMU rendering validation

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

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P2 — make UI geometry aware of the short display

- [x] Remove assumptions that top controls are always 46 pixels high.
- [x] Remove assumptions that bottom controls are always 56 pixels high.
- [x] Introduce board/layout-specific control geometry.
- [x] Keep the normal DMD view full-screen and unobstructed.
- [x] For `Landscape349`, use a temporary overlay or dedicated control screen
      instead of permanent chrome.
- [x] Ensure the full 640×160 DMD remains visible while controls are hidden.
- [x] Test every calculated button rectangle against framebuffer bounds.
- [x] Test simulated touch coordinates for every control zone in QEMU.

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P3 — separate panel hardware from DMD rendering

- [x] Refactor the physical display implementation so `dmd_display.c` does not
      directly assume the Waveshare 7 RGB panel.
- [x] Introduce a board/panel abstraction with separate Waveshare 7 and Waveshare
      3.49B backends, for example:
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

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P4 — identify the exact 3.49B hardware

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

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P5 — minimal physical 3.49B display bring-up

- [x] Create and build the standalone physical panel test and its automated
      flash/serial-evidence runner.
- [x] Initialize PSRAM and the panel, then turn on the backlight.
- [x] Display solid red, green, blue, black, and white frames.
- [x] Display a 640×172 coordinate/grid test pattern.
- [x] Verify landscape orientation and RGB/BGR byte/color order.
- [x] Verify there is no tearing or visible corruption.
- [x] Rerun the panel test continuously for at least 20 minutes with the corrected
      active-low GPIO42 backlight drive.

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P6 — connect the physical panel to the shared DMD renderer

- [x] Connect the 3.49B panel backend to the shared `dmd_display` layer.
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

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / P7 — physical touch bring-up — complete

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

### Waveshare ESP32-S3-Touch-LCD-3.49B — 640×172 landscape TODO / Preview release gate

- [x] P5 illuminated 20-minute panel soak passes.

## Shared

### Documentation consolidation — 2026-08-14

- [x] Make the root README an end-user installation entry point for Windows and ESP32-S3.
- [x] Keep only active unchecked work in the root TODO and archive completed roadmap items by platform.
- [x] Consolidate duplicate setup and release pages into the owning installation guides.
- [x] Move developer-only documentation under `docs/development`.
- [x] Remove stale v1.5 and pre-port roadmap references after the stable v1.6.0 release.

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 3 — animation-library selection

- [x] Define the persisted selection schema before building the UI
- [x] Enable/disable a game or individual animation
- [x] Preserve selections and blocked animations across rescans and restarts
- [x] Preserve selections when files are added, changed, moved, or removed
- [x] Show a live rendered preview and basic metadata for the selected animation

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 3 — animation-library selection / Main application selection

- [x] Allow every valid game and scene on first run, then use persisted disabled-game
      and Disallowed/Unreviewed exceptions to remove content from the playback queue
- [x] Keep individual scene decisions when a game is disabled so re-enabling the game
      restores the same allowed scenes
- [x] Store stable scene ID, last relative path, and SHA-256 fallback information so
      decisions survive renames, moves, temporary removal, restoration, and rescans

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 3 — animation-library selection / Metadata packaging and GitHub updates

- [x] Keep the verified baseline `scenes/scene-metadata.json` in source control while
      continuing to ignore proprietary `.scn` animation files
- [x] Display a release year only when the exact pinball identity and year are verified;
      omit the year entirely when it is missing or uncertain and never infer or guess it

### Replace selected local repositories with fresh clones. / Active roadmap / Priority 3 — animation-library selection / Scene Reviewer

- [x] Add a small dedicated Scene Reviewer interface that groups the installed
      animations by game and places every scene for the selected game in a tiled wall
- [x] Run all scenes on the current page simultaneously and loop them independently
      using the real DMD renderer, compositor, and working clock
- [x] Support `Unreviewed`, `Allowed`, and `Disallowed` states with one-click
      Allow/Disallow controls and an obvious overlay on disallowed tiles
- [x] Make left-click toggle `Allowed` ↔ `Unreviewed`, make right-click toggle
      `Disallowed` ↔ `Allowed`, and let either button replace the opposite decision
- [x] Add page-level Allow/Disallow actions and a library-wide **Allow all** reset so
      a new library needs no approval clicks and exceptions can be removed quickly
- [x] Save every review decision immediately and make DMDClock playback use only
      animations allowed by the persisted library selection
- [x] Add separate numeric `Columns` and `Rows` controls starting at `1 × 1`, with
      independent increment/decrement controls and `columns × rows` scenes per page
- [x] Keep large game groups responsive by using a shared render timer and rendering
      the tiled wall efficiently rather than creating one timer per scene

### Replace selected local repositories with fresh clones. / Completed work

- [x] Embed the complete English translation as the guaranteed fallback, overlay
      valid external English and selected-language files, and log a clear warning
      when an external translation is missing, unreadable, or invalid
- [x] Decide that SmartScreen and antivirus release testing is not a release gate;
      do not purchase signing, reputation, or third-party scanning services for
      this hobby project

### Replace selected local repositories with fresh clones. / Completed work / Additional feature ideas — Animations and library

- [x] Detect new, changed, and removed files during rescans

### Replace selected local repositories with fresh clones. / Completed work / Additional feature ideas — Image and display

- [x] Quick presets for classic orange, red, plasma, and monochrome
- [x] Hide the mouse cursor after five seconds of inactivity over the display

### Replace selected local repositories with fresh clones. / Completed work / Additional feature ideas — Outside project scope

- [x] No audio playback or audio handling

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Animation selection and playback order

- [x] Random selection from all enabled animations
- [x] When reliable time metadata is unavailable, use natural directory/filename sorting and show which order is used
- [x] Read optional `scene-metadata.json` prefix rules and exact file overrides
- [x] Map local `RD####.scn` files to games and scene numbers from `RD Index.txt`
- [x] Skip disabled, missing, or damaged animations without stopping playback
- [x] Display the number of active animations in the current selection

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Appearance

- [x] Classic orange DMD dots
- [x] Thin black border around the dot-matrix display
- [x] No permanent menu bar or visible settings buttons

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Clock

- [x] Selectable 24-hour format
- [x] Selectable 12-hour format
- [x] Optional seconds
- [x] Common selectable date formats: ISO, European, US, and dot-separated
- [x] Display time, play a video/animation, and then return to time
- [x] Make the number of videos between clock displays configurable, defaulting to one
- [x] Make clock duration between animation rounds configurable
- [x] Make clock pauses between animations in the same cycle configurable

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Display

- [x] Regular movable window
- [x] Borderless window with optional title bar and left-click drag movement
- [x] Right-click anywhere in the display to open the complete menu
- [x] Close the menu when clicking outside it or pressing Escape
- [x] Keep the menu open after selecting an option so several settings can be changed consecutively
- [x] Display Alien Tech for four seconds at startup and link Help to the GitHub project
- [x] Store menus in external i18n files with English as default, Swedish translation, and a translation template
- [x] Move a borderless window by left-clicking and dragging
- [x] Space pauses or resumes playback
- [x] T displays the time immediately
- [x] D displays the date immediately when date display is enabled
- [x] I toggles the game and scene information overlay
- [x] F11 toggles fullscreen and Escape leaves fullscreen

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Technology

- [x] Determine whether Java is needed at all
- [x] Document only the old Java code's `.scn` parsing and behavior
- [x] Replace old Java code with a modern native implementation

### Replace selected local repositories with fresh clones. / Completed work / Decisions — Updatable animation library

- [x] Detect new, changed, moved, and removed files without requiring an application update
- [x] Provide automatic watching and manual `Rescan` from the menu
- [x] Use file size, modification time, and content hash for incremental rescans so unchanged files are not decoded again
- [x] Keep the library usable during a large rescan and display discreet status plus the final result
- [x] Use stable library IDs and preserve IDs after content updates or moves when the file can be identified
- [x] Handle files still being copied by detecting changes during scanning and retrying on the next file event
- [x] Write the library index atomically and retain the last valid index when a scan is canceled or fails
- [x] Version the index format; add migration when a second schema version exists
- [x] Report new format versions and unknown files without stopping playback of known files

### Replace selected local repositories with fresh clones. / Completed work / Ideas for later versions — Future — Serum, full color, and larger DMDs

- [x] Add DMD Extensions as a persistent technical reference
- [x] Document the ColorizingDMD guide's Serum workflow as a future reference
- [x] Preserve the isolated prototype for synthetic dumps, six-bit palettes, mask matching, and monochrome fallback as dormant reference code

### Replace selected local repositories with fresh clones. / Completed work / Important checks

- [x] The GitHub repository must not contain proprietary animations, ROM files, or external binary data
- [x] The GitHub repository should contain only our source code, documentation, and freely distributable test resources
- [x] Let users select a local animation directory outside the application and repository
- [x] Use synthetic or project-created minimal `.scn` files in automated tests
- [x] Retain technical source references for projects whose file formats or behavior were studied
- [x] Original resources may be linked from the README, documentation, and download scripts
- [x] Preserve all user-provided original links in `docs/development/reference/SOURCES.md`
- [x] Do not run old Java tools in the final product

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 1 — play a selected SCN file

- [x] Implement a playback engine that follows storyboard frame delays
- [x] Add file opening and play a selected `.scn` file in the existing DMD renderer
- [x] Add play/pause, next frame, and previous frame
- [x] Switch from the clock to an animation and back without freezing the UI
- [x] Add tests for timing, pause, completion, and damaged files

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 2 — select a directory and keep the library updated

- [x] Use `./scenes` as the default directory, create it when needed, and scan it automatically at startup
- [x] Preserve the published `scenes` directory between builds
- [x] Add animation-directory selection and an initial recursive scan
- [x] Create a versioned atomic library index with stable file IDs
- [x] Detect new, changed, and removed `.scn` files incrementally
- [x] Skip damaged files, log the reason, and continue playing valid files
- [x] Log start time, end time, duration, and result for every library scan
- [x] Log transitions between clock, date, and a named animation
- [x] Log application startup with a unique build ID and graceful exit with uptime
- [x] Limit the active log to 3 MiB and rotate one previous log
- [x] Display and log game plus animation scene as small regular text in the lower-right corner at playback start
- [x] Add random and naturally sorted sequential playback

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 3 — basic controls and saved settings

- [x] Implement the context menu with play/pause, next, previous, and show clock
- [x] Add Space, T, D, I, F11, and Escape keyboard shortcuts
- [x] Add borderless fullscreen

### Replace selected local repositories with fresh clones. / Completed work / Next prioritized work — Priority 4 — DotClk fonts

- [x] Make the font selectable and retain the built-in 5×7 font as fallback
- [x] Include an openly licensed TTF font with Swedish characters under `assets/fonts`
- [x] Implement TTF/OTF rendering to a four-bit `DmdFrame`
- [x] Implement and test the original DotClk `.fnt` reader
- [x] Embed ALTERN8, FISHY, TREK, and TWILIGHT in the application
- [x] Make all four DotClk fonts selectable independently for both time and date
- [x] Supply DMD-style fallback date separators without changing the original digit glyphs

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Completion criteria

- [x] Both standalone files run without adjacent DLL files
- [x] Neither standalone file requires an installed .NET runtime
- [x] Settings and user-selected resources persist correctly
- [x] The standalone package and checksums are generated automatically

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone packaging

- [x] Exclude downloaded `.scn` animations from the standalone package
- [x] Create a separate standalone portable ZIP without runtime DLL files
- [x] Archive the previous standalone build before replacement
- [x] Generate and verify SHA-256 checksums automatically

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone publishing profile

- [x] Bundle native libraries with `IncludeNativeLibrariesForSelfExtract=true`
- [x] Enable single-file compression and measure startup time plus file size
- [x] Exclude `.pdb` debugging symbols from distributable builds

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone release validation

- [x] Run all automated tests against the standalone build workflow

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone resources

- [x] Keep `i18n/*.json` outside the executable and load translations from an external `i18n` directory
- [x] Keep downloaded `.scn` animations outside the executable and standalone package
- [x] Document where translations and `.scn` resources can be downloaded and installed
- [x] Retain support for optional user-supplied `.ttf` and `.otf` files
- [x] Verify that missing optional scenes and fonts do not prevent startup
- [x] Embed the four bundled DotClk clock fonts and load them from application resources

### Replace selected local repositories with fresh clones. / Completed work / Standalone EXE/SCR roadmap — Standalone writable-data handling

- [x] Allow scenes and user fonts to be loaded from user-selected directories
- [x] Continue supporting portable `scenes` and `fonts` directories when their location is writable

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 1. Investigate the file format

- [x] Download DotClk Resources from GitHub
- [x] Document the `.scn` format structure
- [x] Compare parsing with the Modern Hackerspace Java code
- [x] Determine which Java behavior must be reimplemented and what can be omitted
- [x] Implement the `.scn` reader directly in the selected modern platform
- [x] Verify frame size, color depth, and frame delays
- [x] Create tests with a few small animation files
- [x] Create an automatic compatibility scan for the complete animation collection
- [x] Verify that every `.scn` file can be opened and decoded without crashing
- [x] Log files with unknown versions, damaged frames, or invalid timing values
- [x] Produce a report with counts of accepted, warned, and rejected files

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 1b. Fonts

- [x] Check which letters, digits, and symbols each font contains
- [x] Add a built-in default font as fallback
- [x] Document the `.fnt` format
- [x] Verify that all four fonts can be read and displayed correctly
- [x] Display available fonts in the clock and date context menus
- [x] Report newly added fonts during resource validation

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 3. Clock functionality

- [x] Create a built-in DMD-friendly numeric font
- [x] Display the current time
- [x] Render each DMD dot as a clearly separated round light against a black background
- [x] Preserve 128×32 resolution and 4:1 aspect ratio at every scale
- [x] Add optional glow and brightness without merging adjacent dots
- [x] Return automatically to the clock when an animation completes
- [x] Add settings for clock interval and animations per cycle

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 4. Settings

- [x] Make implemented settings available from the context menu
- [x] Select animation directory
- [x] Select window size or fullscreen
- [x] Select DMD color and brightness
- [x] Select 12- or 24-hour format
- [x] Select animations between clock displays

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 4b. Local original resources

- [x] Store resources in a local Git-ignored `external/` directory
- [x] Never commit original animations, external binaries, or external projects
- [x] Create `scripts/Get-OriginalResources.ps1`
- [x] Download required original resources from their official GitHub and GitLab locations
- [x] Make the script safe to run repeatedly without duplicates
- [x] Add options to update or download resources again
- [x] Show new, changed, and removed content before or after a resource update
- [x] Store local version, commit, or download information for reproducible tests
- [x] Provide clear errors for network failures or changed download locations
- [x] Keep the application functional without resources and explain how to obtain them

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 5. Distribution

- [x] Use one build script that always archives the previous build before replacing `output/current`
- [x] Store old builds under `output/archive/<timestamp>-<platform>` with a manifest
- [x] Retain the 10 newest archives automatically, with a configurable limit
- [x] Create a self-contained version that requires no separate .NET installation
- [x] Create a portable ZIP

### Replace selected local repositories with fresh clones. / Completed work / Work plan — 6. README and documentation

- [x] Create a structured `README.md`
- [x] Explain the project purpose and what is not included in the repository
- [x] Document bundled fonts, origin, and license
- [x] Document restore, build, test, and publish commands
- [x] Show where local animations and fonts belong
- [x] Explain how to start and control the application
- [x] Document the context menu and keyboard shortcuts
- [x] Link to `docs/development/reference/SOURCES.md` for persistent original-resource and reference links

