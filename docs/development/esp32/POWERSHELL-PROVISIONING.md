# ESP32 PowerShell provisioning design

This document records the v1.6 safety audit and the parameter/staging design
before the mature SD-card and firmware write paths are refactored. Automated
validation of this work must never format, partition, erase, or flash real
hardware.

## Existing flow and risks

`Prepare-DmdClockSdCard.ps1` accepts an explicit physical disk number, verifies
that it exposes exactly one mounted, healthy FAT32 volume, rejects Windows system
and internal disks, and normally requires removable media. It validates a
revision-pinned scene archive and every SCN before copying. Its idempotent sync
preserves obsolete managed scenes and unrelated files. It never partitions,
formats, or deletes card content.

`-AllowFixedDrive` weakens only the removable-media gate and must be used after
the displayed physical identity has been checked. The selected disk identity,
size, bus, partitions, and volume topology are revalidated before copying.

`Flash-DmdClockEsp32.ps1` currently selects the board before the release, rejects
the Waveshare 7B, restricts production 3.49B firmware to V2/Rev1.1, verifies
release metadata and every package hash, and obtains the official portable
Espressif tool. It requires a connected COM port, detects ESP32-S3 and 16 MB
flash, asks for the physical board marking, and retains an exact final `FLASH`
confirmation. Normal application/full writes preserve NVS; factory recovery is
separately revision-gated and replaces internal settings.

The remaining serial risk is lifecycle identity: package/tool verification and
COM enumeration are interleaved, the selected PnP device is not snapshotted and
revalidated immediately before the write, and the final summary lacks some PnP
identity and aggregate firmware hash details. Chip probing cannot identify the
attached display PCB, so the physical label confirmation must remain mandatory.

Before the v1.6 refactor, both scripts allowed Windows PowerShell 5.1. Their
caches and downloads were independent, there was no common complete offline
manifest, and no single
inventory proves that firmware for both supported boards, the selected scene
library, support files, and the verified flashing tool are present. SD support
files fetched from the repository are bounded but not pinned by a staging
manifest. Earlier `-WhatIf` behavior could still populate temporary data, and
neither script wrote a complete per-run evidence log; P2.7 closes both gaps.

Network dependencies are GitHub API/releases/raw content, the sigmafx scene
archive for Original, the DMDClock release archive for DMD-Large, and Espressif's
GitHub release for esptool. No Python, Git, ESP-IDF, .NET, CMake, or Ninja is
needed by the end-user flow. Requirements checks, downloads, offline validation,
already-formatted card synchronization, serial enumeration, and normal flashing
do not inherently require elevation. The entry scripts contain no physical-disk
partition or format stage.

## v1.6 parameter and staging contract

The two entry scripts share `DmdClock.Provisioning.psm1` for Windows 11 x64,
`pwsh` 7+, command, path, free-space, conditional network, elevation, and logging
checks. `-CheckRequirements` is read-only and creates neither directories nor
probe files. Network is checked only for a download operation; a complete local
`-Source` must remain usable with no network.

Staging uses one caller-selected root:

```text
DmdClockFiles/
  staging-manifest.json
  ESP32/
    Waveshare7/
    Waveshare349B/
  SDCard/
    catalog.json
    scene-metadata.json
    template/dmd/
    libraries/<pack-id>/
  Tools/
    esptool/
  Logs/
```

Each inventory item records a stable artifact id, kind, source URL, relative
path, byte size, SHA-256, version, target/revision where applicable, and whether
it was downloaded, reused after verification, or replaced after failed
verification. Downloads use a temporary sibling, validate before an atomic
rename, and remove partial files on failure.

`-DownloadOnly -Destination <path>` never enumerates disks or COM ports. The SD
entry point stages the chosen scene library and support payload; the firmware
entry point stages both supported production firmware packages/manifests and the
portable tool. A small orchestration entry point may invoke both download-only
operations to build and finalize the single complete manifest.

`-Source <path>` first validates the entire relevant staged manifest and every
artifact before disk or COM enumeration. Missing, corrupt, stale, wrong-target,
or wrong-revision content stops the run before hardware access.

Card synchronization now uses explicit physical `-DiskNumber` identity instead
of a drive letter alone. It enumerates candidates and shows disk number, model,
size, bus, partitions, letters, labels, and filesystems; excludes system, boot,
and internal disks; requires exactly one healthy FAT32 volume; snapshots
identity/topology; and re-enumerates it before any write. Partitioning, formatting,
and deletion of card content are intentionally outside the entry scripts.

Flashing will snapshot the selected PnP COM device, verify staged firmware and
tool first, probe the chip, show all hardware/firmware details, revalidate the
same PnP instance immediately before writing, retain board/revision guards, and
retain exact `FLASH` confirmation.

All mutating stages create exactly one non-secret evidence log. Staging writes
under `<Destination>\Logs`; physical SD and flash operations write under
`%LOCALAPPDATA%\DmdClock\Logs\Provisioning`. Each log records host/runtime and
elevation, requirement results, invocation context, URLs, destinations, sizes,
hashes, selected disk or COM identity, tool versions, plans/commands, errors,
duration, and a completed/cancelled/failed outcome. Passwords, tokens,
authorization values, and URL query strings are redacted.

Requirements-only output remains non-mutating. `-WhatIf`/`-DryRun` creates no
log, destination, cache, temporary extraction, card write, or flash and never
opens a serial port. Read-only GitHub availability/release metadata and Windows
disk/COM enumeration may be queried when they are needed to show an exact plan.
