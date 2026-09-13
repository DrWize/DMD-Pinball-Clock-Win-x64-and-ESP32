# DMDClock developer guide

This is the maintained technical guide. Historical guides, release notes,
experiments, and superseded plans are in [`../legacy/`](../legacy/).

## Workstation and desktop application

Use Windows 10/11 x64, Git, .NET 10 SDK, and PowerShell 7. Inno Setup 7 is
required only for the Windows setup EXE.

```powershell
git clone https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32.git
Set-Location DMD-Pinball-Clock-Win-x64-and-ESP32
dotnet restore DMDClock.sln
dotnet build DMDClock.sln -c Debug
dotnet run --project .\src\DmdClock.App\DmdClock.App.csproj
dotnet test DMDClock.sln -c Release
```

Start the Scene Reviewer with `/review`. Optional original resources belong in
the ignored `external` directory and can be fetched with
`scripts\Get-OriginalResources.ps1`.

Build desktop packages with:

```powershell
.\scripts\Build.ps1 -Configuration Release -Runtime win-x64 -NoStart
.\scripts\Build-Installer.ps1
.\scripts\Test-Installer.ps1
.\scripts\Build-MacOS.ps1
```

`Directory.Build.props` supplies the normal version. Build outputs go under
`output\` and must not be committed. The macOS result requires physical Apple
Silicon validation before any release claim.

## ESP32-S3 development

Supported targets are Waveshare ESP32-S3-Touch-LCD-7 (800x480, N16R8) and
ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1 (640x172, N16R8). The 7B and 3.49B V1 are
not supported.

```powershell
.\scripts\esp32\dev\Doctor.ps1
.\scripts\esp32\dev\Build-DmdClock.ps1
.\scripts\esp32\dev\Run-DmdClockQemuModel.ps1 -Model Waveshare7
.\scripts\esp32\dev\Run-DmdClockQemuModel.ps1 -Model Landscape349
```

QEMU is a memory-pressure and integration gate, not a substitute for a physical
panel. Flash an explicitly verified port with the pinned ESP-IDF wrapper:

```powershell
.\scripts\esp32\dev\Invoke-Idf.ps1 `
  -ProjectPath .\firmware\dmdclock-esp32 -p COM5 -B build-hw-esp32 flash monitor
```

Use `Flash-DmdClockEsp32.ps1` and `RUNME-Install-DmdClockEsp32.ps1` for the
published end-user path. Before a destructive card or flash operation, run
`-WhatIf`, verify the physical disk/COM port, and retain the resulting evidence.
Use a FAT32 microSD card; the supplied card layout stores scenes at
`/dmd/scenes` and settings under `/dmd`.

For forgotten web credentials, use `-FlashMode FullReset` or the matching
board-specific `-FactoryRecovery` path. These recovery operations reset NVS and
return the device to first-run setup; ordinary `Application` and `Full` flashes
preserve NVS and do not reset credentials.

The first Wi-Fi bootstrap header is local and Git-ignored. Create it with
`Set-DmdClockBootstrapWifi.ps1`; after confirming home Wi-Fi, remove it with
`Clear-DmdClockBootstrapWifi.ps1` and use `app-flash` without erasing NVS.

```powershell
.\scripts\esp32\dev\Set-DmdClockBootstrapWifi.ps1 -WifiSsid 'Your 2.4 GHz Wi-Fi name' -Build
# After Home Wi-Fi connected is confirmed:
.\scripts\esp32\dev\Clear-DmdClockBootstrapWifi.ps1 -Build
.\scripts\esp32\dev\Invoke-Idf.ps1 `
  -ProjectPath .\firmware\dmdclock-esp32 -p COM5 -B build-hw-esp32 app-flash
```

## Scene metadata and intensity mapping

`scenes/scene-metadata.json` uses `schemaVersion: 1`. It supplies optional
prefix rules and exact file entries; exact entries take precedence. Paths are
relative to the selected scene directory and use `/` separators.

An exact file entry may contain this optional intensity contract:

```json
{
  "path": "example.scn",
  "intensity": {
    "sha256": "64 lowercase hexadecimal characters",
    "frameCount": 120,
    "usedValues": [0, 3, 15],
    "mapping": "evenly-spaced-v1",
    "outputValues": [0, 128, 255]
  }
}
```

`usedValues` is sorted, unique, and contains raw SCN values from 0 through 15.
`outputValues` is the same length and contains the corresponding 0–255 output
levels. The data is accepted only when the mapping name is exact and its SCN
SHA-256, frame count, and used values all match the loaded scene. Missing,
invalid, or stale intensity metadata never blocks playback: the original values
remain in use.

Windows validates the metadata and displays a mapped preview in Scene Reviewer;
normal desktop playback intentionally remains unchanged. ESP32 validates the
same evidence and converts the verified 0–255 mapping into its 16-level runtime
lookup table. SCN source files are immutable. Generation reports and detailed
histograms are analysis artifacts, not runtime input.

## Release and documentation maintenance

Before publication, build and test the intended artifacts, validate both ESP32
targets, and run physical checks where QEMU cannot establish panel behavior.
Preview GitHub publication before releasing; use the real tag in place of the
example:

```powershell
.\scripts\esp32\dev\Package-DmdClockEsp32.ps1 -Board Waveshare7 -CleanOutput
.\scripts\esp32\dev\Package-DmdClockEsp32.ps1 -Board Waveshare349B
.\scripts\Publish-GitHubRelease.ps1 -Tag v1.8.0 -IncludeEsp32 -WhatIf
```

Use explicit Git paths or `git add -p`; this worktree may contain unrelated
changes. `STATUS.md` is the single active record of verified work, blockers, and
next steps. Keep public claims aligned with its physical-acceptance boundary.

The retained documentation under `docs/legacy/` is historical source material;
do not update it instead of this guide or `STATUS.md`.
