# DMDClock standalone installer

The Windows installer packages the standalone `DmdClock.App.exe`, `DMDClock.scr`,
external translations, optional Inter font, the verified baseline
`scenes\scene-metadata.json`, user documentation, compatibility report, and
checksums into one setup EXE.

It uses [Inno Setup](https://jrsoftware.org/isinfo.php) and installs per user without
an administrator prompt.

The current installer, portable ZIP, standalone ZIP, build information, and
checksums are published together on the
[latest release](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest).

## User-visible behavior

- Default installation directory:
  `%LOCALAPPDATA%\Programs\DMDClock`
- Installs both the application and screensaver.
- Creates Start Menu shortcuts for:
  - DMDClock
  - screensaver configuration
  - screensaver preview
  - Windows Screen Saver Settings
  - original DotClk scene downloads
  - local user setup and scene instructions
  - uninstall
- Offers optional Desktop and start-with-Windows shortcuts.
- Offers an optional unchecked task to make DMDClock the active screensaver.
- Offers an unchecked finish-page link to the original sigmafx DotClk Scenes directory.
- Preserves `%LOCALAPPDATA%\DmdClock` settings, logs, and library index during
  upgrades and uninstall.
- If the installer activates DMDClock as the screensaver, uninstall restores the
  previous screensaver. If the user selects another screensaver later, uninstall
  leaves that newer choice alone.
- Does not include downloaded `.scn` animations.
- Includes metadata names and verified years without including proprietary scene
  files.

## Build requirements

- Windows 10/11 x64
- .NET 10 SDK
- PowerShell 7 recommended
- Inno Setup 7 x64

Install the compiler:

```powershell
winget install --id JRSoftware.InnoSetup.7 -e -s winget
```

The build script checks `DMD_ISCC`, the normal per-user and Program Files locations
for Inno Setup 7, and then the equivalent Inno Setup 6 locations.

## Build the application and installer

```powershell
.\scripts\Build-Installer.ps1
```

This first runs `scripts\Build.ps1 -NoStart`, then packages the new standalone
application. It inherits the build script's archive retention behavior.

Use an already published standalone application:

```powershell
.\scripts\Build-Installer.ps1 -SkipApplicationBuild
```

Override compiler discovery:

```powershell
$env:DMD_ISCC = 'C:\Path\To\Inno Setup 7\ISCC.exe'
.\scripts\Build-Installer.ps1 -SkipApplicationBuild
```

Output:

```text
output\current\win-x64-installer\DMDClock-<version>-build<build-number>-win-x64-setup.exe
output\current\win-x64-installer\SHA256SUMS.txt
output\current\win-x64-installer\installer-build-info.json
```

Previous installer packages are archived under
`output\archive\<timestamp>-win-x64-installer`.

## Silent installation

Default silent per-user install:

```powershell
.\DMDClock-*-win-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

Select optional tasks:

```powershell
.\DMDClock-*-win-x64-setup.exe `
  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART `
  /TASKS="desktopicon,autostart,activatescreensaver"
```

Use `/DIR="D:\Apps\DMDClock"` to override the installation directory.

Silent uninstall:

```powershell
& "$env:LOCALAPPDATA\Programs\DMDClock\unins000.exe" `
  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

## Automated local validation

Run the isolated install/reinstall/uninstall test:

```powershell
.\scripts\Test-Installer.ps1
```

The script refuses to run if DMDClock is already registered as installed for the
current user. It installs under `output\installer-validation`, verifies required
files and hashes, temporarily activates the screensaver, repeats the installation,
uninstalls, checks restoration and AppData preservation, and writes a JSON report.

## Installer roadmap and TODO

### Phase 1 — package foundation

- [x] Select a single-EXE Windows installer tool
- [x] Add a stable installer application ID
- [x] Use a non-admin per-user installation directory
- [x] Package the standalone EXE, SCR, translations, font, reports, documentation,
      and screenshots
- [x] Add a repeatable PowerShell installer build
- [x] Generate installer SHA-256 and build metadata
- [x] Archive the previous installer package

### Phase 2 — Windows integration

- [x] Add Start Menu application, configuration, preview, settings, and uninstall shortcuts
- [x] Add Start Menu and finish-page links to the original DotClk scene source
- [x] Add optional Desktop and start-with-Windows tasks
- [x] Add optional screensaver activation
- [x] Preserve and restore the previous screensaver on uninstall
- [x] Leave a screensaver selected later by the user unchanged
- [x] Preserve DMDClock AppData settings during upgrades and uninstall

### Phase 3 — automated local validation

- [x] Compile the installer from a fresh standalone build
- [x] Verify the installer contains all required files
- [x] Run a silent install into an empty directory
- [x] Verify EXE and SCR hashes match the standalone inputs
- [x] Verify optional screensaver activation changes the expected HKCU values
- [x] Run a silent uninstall and verify previous screensaver restoration
- [x] Verify uninstall removes installed program files but retains DMDClock AppData
- [x] Verify a repeat installation preserves the original screensaver restore point
- [x] Test an in-place upgrade over an older installer build

### Phase 4 — release validation

- [x] Test the interactive wizard on clean Windows 10 x64
- [x] Test the interactive wizard on clean Windows 11 x64
- [x] Test without an installed .NET runtime
- [x] Verify Start Menu, Desktop, startup, configuration, preview, and uninstall shortcuts
- [x] Verify add/remove programs metadata and icon
- [x] Skip paid SmartScreen/antivirus reputation testing for this hobby release
- [x] Record Authenticode signing as optional rather than a release requirement;
      paid signing certificates or services are not currently justified
- [ ] Optionally implement Authenticode signing if an affordable suitable option
      becomes available
- [x] Add the setup EXE, portable and standalone ZIPs, build information, and
      generated checksums to the repeatable `Publish-GitHubRelease.ps1` workflow
- [x] Publish and verify the `v1.0.0` GitHub pre-release
- [x] Keep font-licensing research outside the release gates while retaining source
      attribution and recorded hashes

## Completion criteria

The installer is release-ready when:

- clean Windows 10 and 11 systems install, run, upgrade, and uninstall successfully;
- both normal application and screensaver modes work without a .NET installation;
- screensaver activation and restoration never overwrite a later user choice;
- AppData preferences and external scene directories survive upgrades;
- the setup EXE is checksummed and included in a repeatable release process;
- signing remains optional and is not a completion gate for this hobby project.
