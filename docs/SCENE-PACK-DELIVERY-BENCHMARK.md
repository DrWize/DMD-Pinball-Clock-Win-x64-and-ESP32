# ESP32 scene-library delivery benchmark

This benchmark compares the current single-ZIP delivery with downloading every
scene as a separate HTTPS request. It uses **Original DotCLK-Orig** at revision
`11211af`, containing 2,324 scenes; DMD-Large became preferred afterward.

## Result

Keep the ZIP delivery method for ESP32. The controlled comparison produced
byte-identical installed files with no SHA-256 mismatches, while individual-file
delivery required 2,324 requests, transferred 9.08 times as many payload bytes,
and took 75.71 times as long.

| Measurement | One ZIP | Individual files | Difference |
| --- | ---: | ---: | ---: |
| HTTPS payload requests | 1 | 2,324 | 2,324x |
| Payload bytes | 16,814,900 | 152,686,944 | 9.08x |
| Controlled host elapsed time | 6.060 s | 458.779 s | 75.71x |
| Resulting scenes | 2,324 | 2,324 | Identical |
| SHA-256 mismatches | 0 | 0 | None |

The host ZIP time includes downloading, expanding all scenes, and hashing each
result: 3.674 seconds for download and 2.386 seconds for extraction and hashes.
The individual-file time includes downloading, writing, and hashing each scene.
Both paths reused one HTTP client, so the individual test did not deliberately
add connection setup beyond what the server required.

## Actual QEMU ZIP timing

The ZIP workflow was also measured through `/api/scene-pack` on the
Landscape349 QEMU profile with its writable FAT32 image:

| QEMU phase | Elapsed time |
| --- | ---: |
| Catalog retrieval | 9.494 s |
| ZIP download | 55.646 s |
| SHA-256 verification | 18.991 s |
| Extraction, per-file validation, and activation transition | 529.757 s |
| Total | 613.925 s |

Extraction and validation accounted for about 86% of the QEMU installation.
Switching to individual downloads would not remove the need to write and
validate all 2,324 files, but would add 2,323 payload requests and remove the
ZIP's 9.08x transfer-size advantage. It is therefore expected to be slower on
the ESP32 as well; this final statement is an inference from the measured QEMU
ZIP phases and the byte-identical host comparison, because production firmware
does not implement an individual-file download mode.

## Reproduce and inspect logs

Run the actual ZIP workflow against a running QEMU profile:

```powershell
.\scripts\esp32\Measure-ScenePackDelivery.ps1 -Mode QemuZip `
  -PackId dotclk-original -QemuUrl http://127.0.0.1:8081
```

Run the controlled ZIP-versus-individual comparison:

```powershell
.\scripts\esp32\Measure-ScenePackDelivery.ps1 -Mode HostComparison `
  -PackId dotclk-original
```

Each run creates a timestamped directory under
`output/benchmarks/scene-pack-delivery/`. `events.log` records phase or progress
timestamps, `qemu-phases.csv` records one-second QEMU samples,
`single-files.csv` records every individual request, and `summary.json` contains
the final machine-readable measurements. Generated benchmark data is ignored by
Git.
