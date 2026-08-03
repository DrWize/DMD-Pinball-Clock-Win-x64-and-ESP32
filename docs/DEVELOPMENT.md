# Local DMDClock development

Everything required to edit, run, review scenes, test, package, and publish
DMDClock runs locally. ChatGPT and other hosted AI services are optional.

## Requirements

- Windows 10 or Windows 11 x64
- Git
- .NET 10 SDK
- PowerShell 7 recommended
- Visual Studio 2022, JetBrains Rider, or VS Code with C# support
- Inno Setup 7 only when building the setup EXE

Check the command-line tools:

```powershell
git --version
dotnet --info
$PSVersionTable.PSVersion
```

## Clone, restore, and run

```powershell
git clone https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32.git
Set-Location DMD-Pinball-Clock-Win-x64-and-ESP32
dotnet restore DMDClock.sln
dotnet build DMDClock.sln -c Debug
dotnet run --project .\src\DmdClock.App\DmdClock.App.csproj
```

Open the Scene Reviewer directly:

```powershell
dotnet run --project .\src\DmdClock.App\DmdClock.App.csproj -- /review
```

The reviewer, SCN decoding, rendering, clock compositor, file scanning, and
selection persistence all use the local CPU. No scene or preference data is sent
to an AI service.

## Optional original resources

DMDClock builds and runs without the original DotClk repositories. Developers can
download reference sources and local test resources into the Git-ignored
`external` directory:

```powershell
.\scripts\Get-OriginalResources.ps1
```

See [source references](SOURCES.md) for the available selections, provenance, and
update-safety rules.

## Test

```powershell
dotnet test DMDClock.sln -c Release
```

Run a focused test while developing:

```powershell
dotnet test DMDClock.sln -c Release --filter FullyQualifiedName~AnimationSelection
```

## Build distributable packages

Create the portable and standalone Windows packages:

```powershell
.\scripts\Build.ps1 -Configuration Release -Runtime win-x64 -NoStart
```

Create and validate the installer:

```powershell
.\scripts\Build-Installer.ps1
.\scripts\Test-Installer.ps1
```

`Directory.Build.props` is the single source of truth for the semantic
`VersionPrefix`. Use `-Version 1.3.0` only for an intentional one-off override.
Every invocation adds a new UTC millisecond build number and source commit to the
build ID and uses that build number in the ZIP and setup filenames.

`Build-Installer.ps1` also writes
`output\current\release\release-manifest.json`. Installer testing and GitHub
publication resolve the current artifacts from their metadata and this manifest;
they do not depend on hard-coded ZIP or setup filenames.

Build output is generated below `output\` and is intentionally excluded from Git.
Every package contains the tracked `scenes\scene-metadata.json`; downloaded `.scn`
animations are never packaged.

## Build and test ESP32-S3 firmware

The firmware targets the original 800x480 Waveshare ESP32-S3-Touch-LCD-7 with an
N16R8 module. Start by checking the workstation toolchain:

```powershell
.\scripts\esp32\Doctor.ps1
.\scripts\esp32\Build-DmdClock.ps1
```

Build and run the host QEMU validation profile:

```powershell
.\scripts\esp32\Build-DmdClockQemu.ps1
.\scripts\esp32\Run-DmdClockQemu.ps1 -SkipBuild
```

After identifying the board's exact COM port, flash it explicitly and keep the
serial monitor open:

```powershell
.\scripts\esp32\Flash-DmdClock.ps1 -Port COM5 -Monitor
```

Replace `COM5` with the verified port. Read the
[firmware development guide](../firmware/dmdclock-esp32/README.md) before changing
board settings, partitions, Wi-Fi bootstrap data, or release artifacts.

## Publish a GitHub Release

After building and validating all packages, preview release publication:

```powershell
.\scripts\Publish-GitHubRelease.ps1 -Tag v1.1.0 -Prerelease -WhatIf
```

Publish after reviewing the preflight output:

```powershell
.\scripts\Publish-GitHubRelease.ps1 -Tag v1.1.0 -Prerelease
```

The script requires an authenticated GitHub CLI, a clean working tree whose `HEAD`
exactly matches `origin/master`, matching portable/standalone/installer build IDs,
and a tag that does not already exist. It uploads the setup EXE, portable ZIP,
standalone ZIP, installer build information, and a generated SHA-256 file covering
all uploaded build artifacts. Use `-NotesPath path\to\notes.md` for curated release
notes; otherwise GitHub generates notes from the repository history. The current
published build is available through the
[latest release](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest).

## Work with Git

Inspect before staging:

```powershell
git status
git diff
```

Commit one tested, coherent change:

```powershell
git add -p
git commit -m "Describe the completed change"
git push
```

A commit is a local snapshot. A push uploads local commits to GitHub. Commit after
a feature or fix is coherent and tested; push when it should be backed up, shared,
or released. Prefer explicit paths or `git add -p` when unrelated work is present.

## Local data

Runtime files remain under:

```text
%LOCALAPPDATA%\DmdClock\
```

- `settings.json` — application and screensaver preferences
- `library-index.json` — incremental scene index
- `library-selections.json` — shared game and scene decisions
- `logs\dmdclock.log` — diagnostics

Back up this directory before manually changing or removing runtime data.
