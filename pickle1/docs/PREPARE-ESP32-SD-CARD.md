# Prepare an ESP32 microSD card on Windows

This GitHub page is the single authoritative DMDClock source for ESP32 microSD card
requirements and scene-library preparation. Other DMDClock pages and the device
web interface link here instead of maintaining separate card-creation steps.

Use this workflow for the original **Waveshare ESP32-S3-Touch-LCD-7**, 800x480,
N16R8, and **Waveshare ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1**, 640x172,
N16R8. The later 1024x600 `7B` and the incompatible 3.49B V1 are not supported.

The Windows preparation script defaults to preferred **DMD-Large** (2,416
scenes); **Original DotCLK-Orig** (2,324 scenes) remains selectable. It verifies
the published byte count and SHA-256, validates every SCN, and synchronizes the
card. It never partitions, formats, or deletes files from a card, and it refuses
the Windows system volume.

The workflow requires Windows 11 x64, PowerShell 7 or newer running as `pwsh`,
`Prepare-DmdClockSdCard.ps1`, and `DmdClock.Provisioning.psm1`. When the
surrounding repository files are absent,
the script downloads its catalog, metadata, and card-template files from this
repository. SCN validation is built in; Python, .NET, Git, and ESP-IDF are not
required to prepare the card.

## 1. Verify that the intended card is FAT32

The preparation script accepts only one mounted, healthy FAT32 volume on the
explicitly selected physical disk. It stops without changing the card if that
requirement is not met.

Creating, partitioning, and formatting the card are outside the scope of
DMDClock and its scripts. The user is responsible for supplying an already
working FAT32 card and for backing up its contents before using any formatting
tool.

1. Insert the microSD card into the Windows PC.
2. Open **File Explorer > This PC** and note its drive letter, volume label, and
   capacity. Disconnect other removable drives if the identity is ambiguous.
3. If the card is not already FAT32, stop. One option is **Rufus**, downloaded
   only from its official site: [https://rufus.ie/](https://rufus.ie/). Rufus is
   external software and is not supplied, installed, or run by DMDClock. Verify
   the exact device and select FAT32 yourself; formatting erases that device.
4. Reopen **Properties** and confirm that **File system** says `FAT32`.

Windows normally offers FAT32 directly for cards up to 32 GB. Rufus can be useful
when Windows does not offer the required FAT32 choice. A modest card is
recommended because DMDClock needs only about 166 MB for the larger library.
The preparation script deliberately does not partition, format, or delete card
content. It may clean up only temporary files that it created itself if a copy
does not complete.

## 2. Open PowerShell in the repository

```powershell
cd E:\ai\DMDClock-Windows-x64
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

`-Scope Process` applies only to the current PowerShell window.

> Tip: if you are also flashing the board, prefer the single
> [`RUNME-Install-DmdClockEsp32.ps1`](INSTALL-ESP32.md) entry point, which prepares the
> card (or reports it is already up to date) and then flashes in the right order.
> The steps below drive the card step directly.

## 3. Preview the selected library

List physical disks first. The script never chooses one automatically and marks
Windows boot/system disks and internal buses as excluded:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 -ListDisks
```

Match the disk number, model, size, bus, partitions, drive letter, label, and
filesystem. Replace `3` below with that verified physical disk number:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DiskNumber 3 `
  -Library Original `
  -WhatIf
```

For DMD-Large, use:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DiskNumber 3 `
  -Library DmdLarge `
  -WhatIf
```

The preview still downloads and validates the source so that errors are found
before writing, but `-WhatIf` does not change the card.

## 4. Prepare the card

Original DotCLK-Orig:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DiskNumber 3 `
  -Library Original
```

DMD-Large:

```powershell
.\scripts\esp32\Prepare-DmdClockSdCard.ps1 `
  -DiskNumber 3 `
  -Library DmdLarge
```

Review the displayed physical disk, volume, FAT32 status, capacity, selected
library, and file plan before approving the write. The script re-enumerates and
compares the same disk identity and topology immediately before synchronization.
Use `-RefreshSource` when you intentionally want
to download the selected version again instead of reusing its verified cache.

## 5. Verify idempotency and insert the card

Run the same command a second time. A card that already matches must report that
it is up to date and write no files. Switching libraries preserves files from
the previous managed library, unrelated/custom SCNs, and all other card content.
Use a separately prepared empty FAT32 card when you want only one library.

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
- **Volume is not FAT32:** stop and verify the correct card. Back it up and format
  it manually as FAT32 outside the script, then run `-ListDisks` again.
- **Volume is reported as fixed:** some USB readers do this. The physical disk
  must still use USB/SD/MMC and be selected explicitly by disk number; after
  reconfirming every displayed identity field, add `-AllowFixedDrive`.
- **Hash or size mismatch:** do not use the download. Retry with `-RefreshSource`.
- **Validation fails:** no card changes are made before source validation passes.
