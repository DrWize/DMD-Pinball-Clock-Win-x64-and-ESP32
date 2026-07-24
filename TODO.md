# DMDClock for Windows x64 — development TODO

This file is both the contributor runbook and the prioritized backlog. The active
sections contain only unfinished work. Finished items remain in the completed-work
archive so decisions and implementation history are not lost.

## Project goal and scope

DMDClock is a standalone Windows clock and animation player for the classic DotClk
format. It renders a 128×32, four-bit monochrome DMD on a normal monitor and does
not require a Raspberry Pi, Teensy, ESP32, or physical DMD.

Active development is limited to:

- classic 128×32 `.scn` playback;
- storyboard timing, masks, blanking, and clock layers;
- clocks, dates, DotClk/OpenType fonts, and classic DMD themes;
- library indexing, metadata, selection, controls, and Windows packaging.

Audio is outside scope. Serum, cRom, full RGB, larger displays, DMD Extensions,
Raspberry Pi, ESP32-S3, and physical-output support are deferred until the classic
Windows application is release-ready.

## Current baseline

The application, Windows screensaver, portable ZIP, standalone single-file ZIP,
per-user installer, shared scene selection, and live Scene Reviewer are functional.
Automated tests cover SCN parsing/playback, settings, embedded DotClk fonts,
screensaver arguments, library indexing, selection persistence, scene downloads,
and compatibility reporting.

The remaining release blockers are manual Windows validation, read-only-directory
testing, translation fallback behavior, and confirmation that the original DotClk
fonts can be redistributed publicly.

## End-user setup — no source code or SDK required

If you only want to install and use DMDClock, follow this section and stop before
**First-time developer setup**. You do not need Git, PowerShell, Visual Studio, or
the .NET SDK.

### 1. Choose a Windows package

Download a published ZIP from the project's GitHub Releases page. Do not download
GitHub's automatic **Source code** ZIP unless you intend to compile the project.

| Package | Recommended for | What must stay together |
| --- | --- | --- |
| `DMDClock-win-x64-standalone.zip` | Most users | EXE/SCR plus the external `i18n` and optional `fonts` folders |
| `DMDClock-win-x64-portable.zip` | Troubleshooting or conventional self-contained deployment | The complete extracted directory, including every DLL |

The standalone package is recommended. Its EXE and SCR contain the .NET runtime,
Avalonia, native graphics libraries, and the four DotClk fonts. The regular portable
package uses adjacent DLL files; all of those DLLs are required and must not be
deleted.

### 2. Extract the complete ZIP

1. Right-click the downloaded ZIP and open **Properties**.
2. If Windows shows **Unblock**, select it and click **OK**.
3. Select **Extract All**. Do not run DMDClock from inside the ZIP.
4. Extract to a stable location you control, for example:

```text
C:\Users\<your-name>\Apps\DMDClock\
D:\Apps\DMDClock\
```

Avoid a temporary/download directory because the screensaver installation continues
to use `DMDClock.scr` from its extracted location. Keep the complete extracted
folder after installing the screensaver.

The extracted standalone folder should contain at least:

```text
DmdClock.App.exe
DMDClock.scr
i18n\
fonts\
scenes\scene-metadata.json
README.md
build-info.json
SCN-COMPATIBILITY.txt
SHA256SUMS.txt
```

### 3. Verify the standalone download

Open PowerShell in the extracted directory and compare these hashes with
`SHA256SUMS.txt`:

```powershell
Get-FileHash .\DmdClock.App.exe -Algorithm SHA256
Get-FileHash .\DMDClock.scr -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

Only continue through a SmartScreen warning when the package came from the expected
project release and its checksum is trusted. Do not bypass a warning for an
unverified download.

### 4. Start DMDClock for the first time

1. Double-click `DmdClock.App.exe`.
2. Right-click anywhere on the DMD display to open the menu.
3. Choose **Appearance → Clock → Font** and select a clock face.
4. Choose **Appearance → Date → Font** if you want a different date face.
5. Configure color, brightness, glow, clock format, seconds, and date format.
6. Press `T` to show time, `D` to show the date, and `F11` for fullscreen.

Settings are saved automatically under:

```text
%LOCALAPPDATA%\DmdClock\settings.json
```

### 5. Add animations

Animations are not included in either ZIP and must be obtained separately.

Use any of these setups:

- right-click DMDClock and choose **Download DotClk scenes…** to download the
  original scene pack into `%LOCALAPPDATA%\DmdClock\Scenes\DotClk\`;
- create a `scenes` folder beside `DmdClock.App.exe` and copy `.scn` files into it; or
- press `Ctrl+Shift+O` and select an existing animation directory anywhere on the computer.

Subdirectories are scanned recursively. Press `F5` after adding or replacing files.
The app skips damaged files, keeps valid files available, and writes details to:

```text
%LOCALAPPDATA%\DmdClock\logs\dmdclock.log
```

Optional files:

- update the bundled `scene-metadata.json` only with reviewed game/sequence data;
- put extra `.ttf` or `.otf` files anywhere under the extracted `fonts` directory;
- keep `i18n\en.json` and any selected translation beside the binaries.

ALTERN8, FISHY, TREK, and TWILIGHT are already embedded; do not download separate
`.fnt` files for normal use.

### 6. Configure automatic playback

From the right-click menu:

1. enable **Automatic clock/animation cycle**;
2. choose sequential or random order;
3. choose animations per cycle;
4. choose clock duration and the pause between animations;
5. press `T` to start from the clock.

The selected scene directory and playback preferences persist after restart.
Use **Review and choose scenes…** (`Ctrl+Shift+R`) to enable games and allow the
individual animations used by both the normal app and screensaver.

### 7. Install the Windows screensaver

1. Close DMDClock.
2. Right-click `DMDClock.scr` in the extracted folder.
3. Choose **Install**.
4. Select DMDClock in **Windows Screen Saver Settings**.
5. Set the Windows wait time and use **Preview** to test it.
6. Run `DmdClock.App.exe` or `DMDClock.scr /c` whenever you need to change DMDClock settings.

Do not move, rename, or delete the extracted folder after installation. If it must
move, select another screensaver first, move the folder, and install the SCR again.

The screensaver shares the normal application's scene directory and AppData settings.
It exits on a key, click, or deliberate mouse movement.

### 8. Upgrade without losing settings

1. Close DMDClock and select another Windows screensaver temporarily.
2. Extract the new ZIP into a new stable directory.
3. Copy only your portable `scenes`, optional user fonts, and custom translation
   files from the old directory.
4. Start the new `DmdClock.App.exe` and verify the version in `build-info.json`.
5. Reinstall the new `DMDClock.scr`.
6. Delete the old extracted directory only after the new build works.

Preferences and an externally selected scene directory remain under AppData, so
they normally survive an upgrade without copying.

### 9. Common setup problems

- **The EXE reports missing DLLs:** the regular portable package was used without
  all adjacent files. Extract the complete ZIP again or use the standalone package.
- **Menus show internal key names:** restore the package's complete `i18n` folder
  beside the EXE.
- **No animations appear:** confirm the chosen directory contains `.scn` files,
  then press `F5` and check the log for rejected files.
- **A new font does not appear:** place `.ttf`/`.otf` under `fonts`, then reopen the
  right-click menu.
- **The screensaver preview cannot start:** reinstall `DMDClock.scr` from its final
  stable location and keep the package files in place.
- **Settings need to be reset:** close DMDClock, back up
  `%LOCALAPPDATA%\DmdClock`, then remove `settings.json`. The app recreates defaults
  on the next start.
- **The screen is blank:** press `T`, restore brightness to 100%, select Classic
  orange, and verify the foreground/background colors are different.

## First-time developer setup

### Requirements

- Windows 10 or Windows 11 x64
- Git
- .NET 10 SDK
- PowerShell 7 recommended
- VS Code optional; full Visual Studio is not required

Check the tools before restoring:

```powershell
git --version
dotnet --info
$PSVersionTable.PSVersion
```

Clone and enter the repository:

```powershell
git clone https://github.com/DrWize/DMDClock-Windows-x64.git
Set-Location DMDClock-Windows-x64
```

Restore, build, test, and run:

```powershell
dotnet restore DMDClock.sln
dotnet build DMDClock.sln -c Debug
dotnet test DMDClock.sln -c Release
dotnet run --project .\src\DmdClock.App\DmdClock.App.csproj
```

The application works without downloaded original resources. Add `.scn` files to
`.\scenes`, choose another directory with `Ctrl+Shift+O`, or use the optional
resource workflow below.

### Local .NET SDK override

`scripts/Build.ps1` looks for the SDK in this order:

1. the executable specified by `DMD_DOTNET`;
2. `..\.tools\dotnet10\dotnet.exe` relative to the repository;
3. `dotnet` from `PATH`.

Example override:

```powershell
$env:DMD_DOTNET = 'C:\Program Files\dotnet\dotnet.exe'
.\scripts\Build.ps1 -NoStart
```

## Optional original resources

Original repositories and animation files are not required for normal compilation.
The download script stores them under the Git-ignored `external\` directory and
writes reproducibility metadata there.

Download all missing reference repositories:

```powershell
.\scripts\Get-OriginalResources.ps1
```

Useful variants:

```powershell
# Download only the original scene/font resource repository.
.\scripts\Get-OriginalResources.ps1 -Resource DotClk-Resources

# Fast-forward existing clean repositories and report changes.
.\scripts\Get-OriginalResources.ps1 -Update

# Preview an update without changing files.
.\scripts\Get-OriginalResources.ps1 -Update -WhatIf

# Replace selected local repositories with fresh clones.
.\scripts\Get-OriginalResources.ps1 -Resource DotClk-Resources -Redownload
```

Do not use `-Redownload` when an external repository contains local work that has
not been copied elsewhere. See `docs\SOURCES.md` for sources and safety details.

## Common development commands

### Build and test

```powershell
dotnet build DMDClock.sln -c Debug
dotnet test DMDClock.sln -c Release
```

Run one test class while iterating:

```powershell
dotnet test DMDClock.sln -c Release --filter FullyQualifiedName~DotClkFont
```

Run the application from source:

```powershell
dotnet run --project .\src\DmdClock.App\DmdClock.App.csproj
```

### Inspect an SCN collection

`scan` reads every `.scn` recursively and reports accepted, warned, and rejected
files. It exits with code `1` when any file is rejected.

```powershell
dotnet run --project .\tools\DmdClock.Tools\DmdClock.Tools.csproj -- scan .\scenes
```

`index` exercises the library scanner and reports the same high-level counts:

```powershell
dotnet run --project .\tools\DmdClock.Tools\DmdClock.Tools.csproj -- index .\scenes
```

Use `Ctrl+O` in the application to test one file. Use `F5` after adding files to the
active library.

### Generate RD scene metadata

This script matches local `RD####.scn` files against the original `RD Index.txt`
and writes `scenes\scene-metadata.json`.

Prerequisites:

- `external\DotClk-Resources\RD Index.txt` exists;
- matching `RD*.scn` files exist under `scenes\`.

```powershell
.\scripts\Map-RdScenes.ps1
```

Override paths when the index or scene library is elsewhere:

```powershell
.\scripts\Map-RdScenes.ps1 `
  -IndexPath 'D:\DotClk\RD Index.txt' `
  -ScenesDirectory 'D:\DMD Scenes' `
  -MetadataPath 'D:\DMD Scenes\scene-metadata.json'
```

### Render DotClk font previews

The preview script reads the original `.fnt` files and produces one PNG per font:

```powershell
.\scripts\Render-DotClkFontPreviews.ps1
```

Default input and output:

```text
external\DotClk-Resources\Fonts\
output\font-previews\
```

### Create distributable Windows builds

Recommended non-interactive release build:

```powershell
dotnet test DMDClock.sln -c Release
.\scripts\Build.ps1 -NoStart
```

Run and start the newly published regular application:

```powershell
.\scripts\Build.ps1
```

Useful build options:

```powershell
.\scripts\Build.ps1 -Configuration Debug -NoStart
.\scripts\Build.ps1 -Runtime win-x64 -MaxArchivedBuilds 20 -NoStart
```

`Build.ps1` has intentional side effects:

- closes running `DmdClock.App.exe`, `DMDClock.scr`, and related tool processes;
- publishes regular self-contained and standalone single-file builds;
- copies the existing regular-build scene library forward;
- runs the SCN compatibility scan;
- creates reports, checksums, and both ZIP packages;
- archives the previous current builds;
- retains 10 archive directories by default and permanently removes older ones.

Build outputs:

```text
output\current\win-x64\
output\current\win-x64\DMDClock-win-x64-portable.zip
output\current\win-x64-standalone\
output\current\win-x64-standalone\DMDClock-win-x64-standalone.zip
output\archive\
```

Do not distribute files directly from `output\.staging\`. A successful build moves
the completed packages into `output\current\`.

## Runtime files and local data

External files beside a published build:

- `i18n\*.json` — translations; required for localized menus;
- `fonts\**\*.ttf` and `*.otf` — optional user-installed fonts;
- `scenes\**\*.scn` — optional portable scene library;
- `scenes\scene-metadata.json` — optional game/sequence metadata.

ALTERN8, FISHY, TREK, and TWILIGHT are embedded and require no adjacent `.fnt`
files. Downloaded scenes remain external to the standalone EXE and SCR.

Writable runtime data is stored under:

```text
%LOCALAPPDATA%\DmdClock\
```

- `settings.json` — saved preferences and selected paths;
- `library-index.json` — incremental library index;
- `library-selections.json` — enabled games and Allowed, Disallowed, or Unreviewed
  scene decisions shared by the app and screensaver;
- `logs\dmdclock.log` — active log;
- `logs\dmdclock.log.previous` — rotated log.

Generated and local-only directories such as `bin\`, `obj\`, `external\`, `output\`,
and scene content are ignored by Git.

## Manual Windows test checklist

Before calling a build release-ready:

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
- [ ] Check startup time, temporary native extraction, package size, SmartScreen,
      and antivirus results

Screensaver checks:

```powershell
& .\output\current\win-x64-standalone\DMDClock.scr /c
& .\output\current\win-x64-standalone\DMDClock.scr /s
```

- [ ] Verify `/c` opens configuration mode
- [ ] Verify `/s` opens fullscreen and exits on keyboard, click, or deliberate mouse movement
- [ ] Right-click `DMDClock.scr`, choose **Install**, and select it in Windows Screen Saver Settings
- [ ] Verify the Control Panel `/p <HWND>` preview is embedded and closes cleanly
- [ ] Repeat standalone tests on clean Windows 10 and Windows 11 x64 machines
      without an installed .NET runtime

## Definition of done

A completed item must include:

- implementation and focused automated tests;
- the full `dotnet test DMDClock.sln -c Release` suite passing;
- relevant manual UI or screensaver validation;
- documentation for new commands, settings, resources, or output files;
- no downloaded animations, ROMs, secrets, or generated output staged in Git;
- a checked item moved from active work to the completed archive.

## Active roadmap

### Priority 1 — release validation and robustness

- [ ] Provide an English built-in translation fallback and a clear warning when
      external translations are missing or invalid
- [ ] Ensure startup and normal operation never require write access beside the executable
- [ ] Complete every item in the manual Windows test checklist above
- [ ] Confirm redistribution terms for ALTERN8, FISHY, TREK, and TWILIGHT before
      publishing a public binary release; until then, keep the files embedded with
      their sigmafx source, source commit, hashes, and unresolved license status documented
- [ ] Verify SmartScreen and antivirus behavior for both EXE and SCR
- [ ] Consider trimming only after the untrimmed standalone build passes all release tests

Acceptance criteria:

- both ZIPs work from read-only directories on clean Windows 10/11 x64;
- the screensaver works in `/s`, `/c`, installed, and Control Panel preview modes;
- missing optional scenes/fonts and missing or invalid translations do not crash startup;
- all writable data stays under `%LOCALAPPDATA%\DmdClock`.

### Priority 2 — VS Code development setup

- [ ] Add `.vscode\extensions.json` with the required/recommended C# tooling
- [ ] Add `.vscode\tasks.json` for restore, build, test, run, compatibility scan,
      and release packaging
- [ ] Add `.vscode\launch.json` for debugging the Avalonia application
- [ ] Verify every VS Code task has an equivalent documented PowerShell command
- [ ] Add troubleshooting for SDK discovery, missing resources, bad SCN files,
      graphics problems, and locked build output

Acceptance criteria:

- a fresh clone can be restored, tested, run, and debugged from VS Code without
  full Visual Studio or user-specific project files.

### Priority 3 — animation-library selection

- [x] Define the persisted selection schema before building the UI
- [ ] Add manufacturer → game → animation browsing with search
- [ ] Add `Select all`, `Clear all`, and `Reset`
- [x] Enable/disable a game or individual animation
- [x] Preserve selections and blocked animations across rescans and restarts
- [x] Preserve selections when files are added, changed, moved, or removed
- [ ] Support all enabled animations, manufacturer, game, random, sequential,
      and chronological playback modes
- [x] Show a live rendered preview and basic metadata for the selected animation
- [ ] Add focused migration, persistence, and playback-selection tests

#### Metadata packaging and GitHub updates

- [x] Keep the verified baseline `scenes/scene-metadata.json` in source control while
      continuing to ignore proprietary `.scn` animation files
- [x] Include the baseline metadata JSON in every regular ZIP, standalone EXE package,
      screensaver package, and installer build so a clean clone and every published
      build have useful metadata without a separate download
- [ ] Load metadata in layers: bundled baseline, newer validated GitHub update, then
      optional library-local overrides, with later layers overriding matching entries
- [ ] Add a versioned GitHub metadata manifest containing schema version, metadata
      version, publication time, download URL, and SHA-256 checksum
- [ ] Add **Check for metadata updates…** to the regular app and screensaver
      configuration mode; download updates over HTTPS, validate schema and checksum,
      and replace the AppData copy atomically only after complete validation
- [ ] Store downloaded metadata under `%LOCALAPPDATA%\DmdClock\metadata\`, retain the
      bundled version as an offline fallback, and retain the last known-good downloaded
      version when an update is missing, damaged, incompatible, or unavailable
- [ ] Make regular app and screensaver playback observe the same validated metadata
      update without requiring either installation directory to be writable
- [x] Display a release year only when the exact pinball identity and year are verified;
      omit the year entirely when it is missing or uncertain and never infer or guess it
- [ ] Add a GitHub issue form for metadata additions and corrections requiring game,
      exact machine/version, release year, affected files or RD range, and a reliable
      evidence link; only reviewed data may enter the published metadata
- [ ] Add packaging, precedence, offline fallback, checksum failure, schema migration,
      concurrent reload, and clean-build metadata tests

#### Main application selection

- [ ] Add a dedicated **Choose games and scenes…** window to the main DMDClock
      application, opened from the context menu without cluttering the clock display
- [ ] Show enabled games and the allowed scenes for the selected game side by side,
      with search, per-game scene counts, and `Select all`, `Clear all`, and `Reset`
- [x] Allow every valid game and scene on first run, then use persisted disabled-game
      and Disallowed/Unreviewed exceptions to remove content from the playback queue
- [x] Keep individual scene decisions when a game is disabled so re-enabling the game
      restores the same allowed scenes
- [x] Store stable scene ID, last relative path, and SHA-256 fallback information so
      decisions survive renames, moves, temporary removal, restoration, and rescans
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

#### Scene Reviewer

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
- [ ] Preserve the 128×32 DMD aspect ratio, resize tiles to fill the available window,
      remember the chosen rows and columns, and provide an optional automatic-fit mode
- [ ] Add previous/next-page controls, scene ranges, and per-game plus overall counts
      for allowed, disallowed, and unreviewed animations
- [ ] Add filters for all, allowed, disallowed, and unreviewed scenes, plus pause,
      replay, and enlarged single-scene inspection
- [x] Keep large game groups responsive by using a shared render timer and rendering
      the tiled wall efficiently rather than creating one timer per scene
- [ ] Add tests for grid sizing, pagination, immediate persistence, state restoration,
      filtering, and propagation of Allow/Disallow decisions into playback

Acceptance criteria:

- every clean and published app/screensaver build contains a verified baseline metadata
  JSON and continues working when GitHub is unavailable;
- an invalid or interrupted metadata update can never replace the last known-good copy;
- verified GitHub metadata updates become available to both app and screensaver without
  modifying installed files or user selection decisions;
- adding new files never resets existing enablement or block choices;
- every playback mode uses only the active selection and skips invalid files;
- disabling and re-enabling a game restores its previous individual scene decisions;
- a newly discovered valid scene starts Allowed, while Unreviewed and Disallowed
  exceptions never enter playback;
- the main selector, reviewer, and playback queue always resolve the same saved state;
- regular app and screensaver playback use the same selection concurrently and refresh
  safely after a saved change without interrupting the scene currently playing;
- every visible reviewer tile plays the complete scene with a working clock;
- repeated left-clicks alternate between Allowed and Unreviewed, repeated
  right-clicks alternate between Disallowed and Allowed, and switching mouse button
  replaces the previous decision;
- **Allow all** resets every game and valid scene to Allowed;
- changing rows or columns immediately rebuilds the page without losing decisions.

### Priority 4 — display and daily operation

- [ ] Select and persist the target monitor
- [ ] Recover gracefully when the selected monitor is disconnected
- [ ] Add start-with-Windows and always-on-top options
- [ ] Add a discreet paused indicator
- [ ] Add explicit enable/disable settings for clock, date, and animations
- [ ] Add an optional weekday display
- [ ] Add a system-tray icon with pause, show clock, next animation, and exit
- [ ] Resume the last safe mode after restart or power failure
- [ ] Export/import settings and create an automatic pre-migration backup
- [ ] Add a diagnostics view for file, frame, timing, resolution, and decoder errors
- [ ] Add silent fullscreen error handling that logs and skips broken content

### Priority 5 — installer and release automation

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
- [ ] Test an in-place upgrade from an older installer build
- [ ] Test the interactive installer on clean Windows 10 and Windows 11 without .NET
- [ ] Decide code-signing and release-checksum procedures
- [ ] Add the signed setup EXE to a repeatable GitHub release workflow

Detailed status, commands, and acceptance criteria:
[`docs/INSTALLER.md`](docs/INSTALLER.md).

## Backlog after the active priorities

### Clock and automatic display

- [ ] Multiple clock layouts with optional seconds/date
- [ ] Blinking-colon seconds mode
- [ ] Immediate, fade, and DMD-dissolve transitions
- [ ] Active/dim/off schedules and separate day/night brightness
- [ ] Burn-in protection through small position shifts and rotating layouts
- [ ] Multiple automatically rotating time zones
- [ ] Weather integration

### Animations and library

- [ ] Avoid replaying an animation until the active selection has been exhausted
- [ ] Playback history and temporary `Do not show again`
- [ ] Per-animation duration, repeat count, and short-animation looping
- [ ] Custom metadata corrections, thumbnails, and duplicate-file handling
- [ ] Curate consistent names and metadata for known SCN collections

### Appearance

- [ ] Scrolling C64-inspired palettes/raster bars with direction, speed, and disable controls
- [ ] Selectable dot shape, spacing, and glow strength
- [ ] Per-manufacturer or per-game color palettes
- [ ] Pixel-perfect integer scaling when the available display size permits it

## Deferred future work

Do not connect these items to the active application until the classic Windows
release criteria are complete:

- Raspberry Pi builds and shared cross-platform packaging
- a versioned platform-independent `DmdFrame` interchange format
- ESP32-S3 conversion, manifests, SD-card packages, rollback, and network updates
- Serum, cRom, VNI/PAL/PAC, indexed color, RGB24, and DMD Extensions validation
- 192×64 and 256×64 displays
- physical LED matrix, Pin2DMD, and network-adapter output
- GIF/MP4 import, mobile remote control, favorites, and named playlists
- GPL integration-boundary and third-party colorization-license research

## Completed work

Completed items are retained here as the project history.

- [x] Add a safe in-app DotClk scene-pack downloader with progress, cancellation,
      atomic installation, AppData storage, automatic selection, and rescanning
### Next prioritized work — Priority 1 — play a selected SCN file

- [x] Implement a playback engine that follows storyboard frame delays
- [x] Implement storyboard first/last steps, blanking, transparency masks, and clock layers according to the original firmware
- [x] Add file opening and play a selected `.scn` file in the existing DMD renderer
- [x] Add play/pause, next frame, and previous frame
- [x] Switch from the clock to an animation and back without freezing the UI
- [x] Add tests for timing, pause, completion, and damaged files

### Next prioritized work — Priority 2 — select a directory and keep the library updated

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

### Next prioritized work — Priority 3 — basic controls and saved settings

- [x] Implement the context menu with play/pause, next, previous, and show clock
- [x] Save automatic cycle, intervals, animation count, and random/sequential mode in AppData
- [x] Add Space, T, D, I, F11, and Escape keyboard shortcuts
- [x] Add borderless fullscreen
- [x] Save animation directory, playback mode, interval, color, and brightness in AppData

### Next prioritized work — Priority 4 — DotClk fonts

- [x] Make the font selectable and retain the built-in 5×7 font as fallback
- [x] Include an openly licensed TTF font with Swedish characters under `assets/fonts`
- [x] Implement TTF/OTF rendering to a four-bit `DmdFrame`
- [x] Implement and test the original DotClk `.fnt` reader
- [x] Embed ALTERN8, FISHY, TREK, and TWILIGHT in the application
- [x] Make all four DotClk fonts selectable independently for both time and date
- [x] Supply DMD-style fallback date separators without changing the original digit glyphs

### Next prioritized work — Priority 5 — first distributable Windows build

- [x] Complete the README
- [x] Create a self-contained `win-x64` build
- [x] Verify that the previous build is archived before every new build
- [x] Run a complete SCN compatibility scan and store its report with the build
- [x] Create a portable ZIP
- [x] Create standalone single-file Windows `.exe` and `.scr` builds

### Decisions — Technology

- [x] Determine whether Java is needed at all
- [x] Document only the old Java code's `.scn` parsing and behavior
- [x] Replace old Java code with a modern native implementation
- [x] C# with .NET 10 LTS and Avalonia UI for Windows and Raspberry Pi

### Decisions — Appearance

- [x] Classic orange DMD dots
- [x] Thin black border around the dot-matrix display
- [x] No permanent menu bar or visible settings buttons

### Decisions — Display

- [x] Regular movable window
- [x] Borderless window with optional title bar and left-click drag movement
- [x] Optional Windows x64 screensaver (`.scr`) using the same clock, animations, and settings
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

### Decisions — Clock

- [x] Selectable 24-hour format
- [x] Selectable 12-hour format
- [x] Optional seconds
- [x] Common selectable date formats: ISO, European, US, and dot-separated
- [x] Display time, play a video/animation, and then return to time
- [x] Make the number of videos between clock displays configurable, defaulting to one
- [x] Make clock duration between animation rounds configurable
- [x] Make clock pauses between animations in the same cycle configurable

### Decisions — Animation selection and playback order

- [x] Random selection from all enabled animations
- [x] When reliable time metadata is unavailable, use natural directory/filename sorting and show which order is used
- [x] Read optional `scene-metadata.json` prefix rules and exact file overrides
- [x] Map local `RD####.scn` files to games and scene numbers from `RD Index.txt`
- [x] Skip disabled, missing, or damaged animations without stopping playback
- [x] Display the number of active animations in the current selection

### Decisions — Updatable animation library

- [x] Detect new, changed, moved, and removed files without requiring an application update
- [x] Provide automatic watching and manual `Rescan` from the menu
- [x] Use file size, modification time, and content hash for incremental rescans so unchanged files are not decoded again
- [x] Keep the library usable during a large rescan and display discreet status plus the final result
- [x] Use stable library IDs and preserve IDs after content updates or moves when the file can be identified
- [x] Handle files still being copied by detecting changes during scanning and retrying on the next file event
- [x] Write the library index atomically and retain the last valid index when a scan is canceled or fails
- [x] Version the index format; add migration when a second schema version exists
- [x] Report new format versions and unknown files without stopping playback of known files

### Work plan — 1. Investigate the file format

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

### Work plan — 1b. Fonts

- [x] Check which letters, digits, and symbols each font contains
- [x] Add a built-in default font as fallback
- [x] Document the `.fnt` format
- [x] Verify that all four fonts can be read and displayed correctly
- [x] Display available fonts in the clock and date context menus
- [x] Report newly added fonts during resource validation

### Work plan — 2. Basic Windows application

- [x] Create a .NET 10 project targeting Windows x64
- [x] Create a regular `.sln` and clearly organized `.csproj` projects
- [x] Create a main window with a 4:1 aspect ratio
- [x] Implement the first DMD renderer using separated round dots
- [x] Add a thin black border around the display
- [x] Implement the complete context menu in the display
- [x] Add an open-directory dialog
- [x] Add start, stop, next, and previous animation
- [x] Display clear error messages for damaged or unknown files

### Work plan — 3. Clock functionality

- [x] Create a built-in DMD-friendly numeric font
- [x] Display the current time
- [x] Render each DMD dot as a clearly separated round light against a black background
- [x] Preserve 128×32 resolution and 4:1 aspect ratio at every scale
- [x] Add optional glow and brightness without merging adjacent dots
- [x] Return automatically to the clock when an animation completes
- [x] Add settings for clock interval and animations per cycle

### Work plan — 4. Settings

- [x] Make implemented settings available from the context menu
- [x] Select animation directory
- [x] Select window size or fullscreen
- [x] Select DMD color and brightness
- [x] Select 12- or 24-hour format
- [x] Select animations between clock displays
- [x] Save implemented settings under the user's AppData directory

### Work plan — 4b. Local original resources

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

### Work plan — 5. Distribution

- [x] Use one build script that always archives the previous build before replacing `output/current`
- [x] Close related DMDClock processes before building and start the new Windows build after successful publication
- [x] Store old builds under `output/archive/<timestamp>-<platform>` with a manifest
- [x] Retain the 10 newest archives automatically, with a configurable limit
- [x] Publish the current Windows x64 distribution
- [x] Create a self-contained version that requires no separate .NET installation
- [x] Create a portable ZIP

### Work plan — 6. README and documentation

- [x] Create a structured `README.md`
- [x] Explain the project purpose and what is not included in the repository
- [x] Show how to build for Windows x64
- [x] Document bundled fonts, origin, and license
- [x] Document restore, build, test, and publish commands
- [x] Show where local animations and fonts belong
- [x] Explain how to start and control the application
- [x] Document the context menu and keyboard shortcuts
- [x] Link to `docs/SOURCES.md` for persistent original-resource and reference links

### Important checks

- [x] The GitHub repository must not contain proprietary animations, ROM files, or external binary data
- [x] The GitHub repository should contain only our source code, documentation, and freely distributable test resources
- [x] Let users select a local animation directory outside the application and repository
- [x] Use synthetic or project-created minimal `.scn` files in automated tests
- [x] Retain technical source references for projects whose file formats or behavior were studied
- [x] Original resources may be linked from the README, documentation, and download scripts
- [x] Preserve all user-provided original links in `docs/SOURCES.md`
- [x] Do not run old Java tools in the final product

### Ideas for later versions — Future — Serum, full color, and larger DMDs

- [x] Add DMD Extensions as a persistent technical reference
- [x] Document the ColorizingDMD guide's Serum workflow as a future reference
- [x] Preserve the isolated prototype for synthetic dumps, six-bit palettes, mask matching, and monochrome fallback as dormant reference code
- [x] Windows screensaver mode

### Additional feature ideas — Animations and library

- [x] Detect new, changed, and removed files during rescans

### Additional feature ideas — Image and display

- [x] Quick presets for classic orange, red, plasma, and monochrome
- [x] Hide the mouse cursor after five seconds of inactivity over the display

### Additional feature ideas — Outside project scope

- [x] No audio playback or audio handling

### Standalone EXE/SCR roadmap — Standalone resources

- [x] Keep `i18n/*.json` outside the executable and load translations from an external `i18n` directory
- [x] Keep downloaded `.scn` animations outside the executable and standalone package
- [x] Document where translations and `.scn` resources can be downloaded and installed
- [x] Retain support for optional user-supplied `.ttf` and `.otf` files
- [x] Verify that missing optional scenes and fonts do not prevent startup
- [x] Embed the four bundled DotClk clock fonts and load them from application resources

### Standalone EXE/SCR roadmap — Standalone publishing profile

- [x] Publish self-contained for `win-x64` with `PublishSingleFile=true`
- [x] Bundle native libraries with `IncludeNativeLibrariesForSelfExtract=true`
- [x] Enable single-file compression and measure startup time plus file size
- [x] Exclude `.pdb` debugging symbols from distributable builds
- [x] Keep trimming disabled initially and document the Avalonia reflection constraint

### Standalone EXE/SCR roadmap — Standalone binary generation

- [x] Publish one standalone `DmdClock.App.exe`
- [x] Copy the verified standalone executable to `DMDClock.scr`

### Standalone EXE/SCR roadmap — Standalone writable-data handling

- [x] Verify settings and library indexes are stored under `%LOCALAPPDATA%\DmdClock`
- [x] Allow scenes and user fonts to be loaded from user-selected directories
- [x] Continue supporting portable `scenes` and `fonts` directories when their location is writable

### Standalone EXE/SCR roadmap — Standalone packaging

- [x] Extend `scripts/Build.ps1` to create `output/current/win-x64-standalone`
- [x] Include `DmdClock.App.exe`, `DMDClock.scr`, external `i18n`, `README.md`, `build-info.json`, and `SHA256SUMS.txt`
- [x] Exclude downloaded `.scn` animations from the standalone package
- [x] Create a separate standalone portable ZIP without runtime DLL files
- [x] Archive the previous standalone build before replacement
- [x] Generate and verify SHA-256 checksums automatically

### Standalone EXE/SCR roadmap — Standalone release validation

- [x] Run all automated tests against the standalone build workflow

### Standalone EXE/SCR roadmap — Completion criteria

- [x] Both standalone files run without adjacent DLL files
- [x] Neither standalone file requires an installed .NET runtime
- [x] Settings and user-selected resources persist correctly
- [x] The standalone package and checksums are generated automatically
