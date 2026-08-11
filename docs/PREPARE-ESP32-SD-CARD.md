# Prepare an ESP32 TF card on Windows

Use this workflow for the original **Waveshare ESP32-S3-Touch-LCD-7**, 800x480,
N16R8. The later 1024x600 `7B` is not supported.

The Windows preparation script defaults to preferred **DMD-Large** (2,416
scenes); **Original DotCLK-Orig** (2,324 scenes) remains selectable. It verifies
the published byte count and SHA-256, validates every SCN, and synchronizes the
card. It never formats a card and refuses the Windows system volume.

The workflow requires Windows PowerShell 5.1 or newer and
`Prepare-DmdClockSdCard.ps1`. When the surrounding repository files are absent,
the script downloads its catalog, metadata, and card-template files from this
repository. SCN validation is built in; Python, .NET, Git, and ESP-IDF are not
required to prepare the card.

## 1. Identify and format the correct card

Back up anything important on the TF card before formatting it. Formatting
erases the selected volume.

1. Insert the TF card into the Windows PC.
2. Open **File Explorer > This PC** and note its drive letter, volume label, and
   capacity. Disconnect other removable drives if the identity is ambiguous.
3. If the card is not already FAT32, right-click that exact volume, select
   **Format**, choose **FAT32**, leave **Quick Format** enabled, and verify the
   drive letter and capacity again before selecting **Start**.
4. Reopen **Properties** and confirm that **File system** says `FAT32`.

Windows normally offers FAT32 directly for cards up to 32 GB. A modest card is
recommended because DMDClock needs only about 166 MB for the larger library.
The preparation script deliberately does not partition or format media.

## 2. Open PowerShell in the repository

```powershell
cd E:\ai\DMDClock-Windows-x64
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

`-Scope Process` applies only to the current PowerShell window.

## 3. Preview the selected library

Replace `J` with the verified TF-card drive letter:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DriveLetter J `
  -Library Original `
  -WhatIf
```

For DMD-Large, use:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DriveLetter J `
  -Library DmdLarge `
  -WhatIf
```

The preview still downloads and validates the source so that errors are found
before writing, but `-WhatIf` does not change the card.

## 4. Prepare the card

Original DotCLK-Orig:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DriveLetter J `
  -Library Original
```

DMD-Large:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DriveLetter J `
  -Library DmdLarge
```

Review the displayed target, FAT32 status, capacity, selected library, and file
plan before approving the write. Use `-RefreshSource` when you intentionally want
to download the selected version again instead of reusing its verified cache.

## 5. Verify idempotency and insert the card

Run the same command a second time. A card that already matches must report that
it is up to date and write no files. Switching libraries removes only files
recorded as managed by the previous run; unrelated/custom SCNs and other card
content remain untouched.

Use **Safely Remove Hardware and Eject Media**, power off the ESP32, insert the
card, and power it on. The firmware should index exactly 2,324 scenes for Original
DotCLK-Orig or 2,416 for DMD-Large.

The managed layout is:

```text
<card>:\dmd\scenes\
<card>:\dmd\config\scene-library-manifest.json
```

## Troubleshooting

- **Scripts are disabled:** run the process-scoped execution-policy command from
  step 2 in the same PowerShell window.
- **Volume is not FAT32:** stop and verify the correct card. The script will not
  reformat it.
- **Drive is reported as fixed:** some USB readers do this. Reconfirm the exact
  device in File Explorer, then add `-AllowFixedDrive` explicitly.
- **Hash or size mismatch:** do not use the download. Retry with `-RefreshSource`.
- **Validation fails:** no card changes are made before source validation passes.
