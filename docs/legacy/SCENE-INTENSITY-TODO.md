# Scene intensity tracking — P0 to P5

Created: 2026-09-12. Scope: raw SCN intensity discovery and consistent diagnostics, with the user's proposed scene brightness mapping targeting Waveshare ESP32-S3 3.49B V2 first. Windows, Waveshare 7, and macOS integration are deferred for this first implementation. The 2026-09-12 findings and proposal below supersede the earlier diagnostics-only restriction for this target; this update records the proposal only and does not implement it.

## P0 — Define the measurement

- [x] Closed 2026-09-12: Count distinct source values 0–15 across every stored frame, including black. Also report nonzero count, sorted values, and a 16-bin histogram.
- [x] Closed 2026-09-12: Keep raw analysis independent of display brightness, palettes, glow, masks, clock overlays, and frame duration. Include masked pixels; exclude unused packed-row padding.
- [x] Closed 2026-09-12: Local reference `scene_00.scn` uses 12 levels: `0,2,4,6,7,8,9,10,11,12,13,15`; `scene_01.scn` uses 4: `0,5,8,15`. These build-directory names are not permanent identities: record SHA-256 with each report.

## P1 — Reusable PowerShell inventory

- [x] Closed 2026-09-12: Add `scripts/SceneIntensity.psm1` for reusable single-file analysis, including per-frame histograms.
- [x] Closed 2026-09-12: Add `scripts/Export-SceneIntensityLevels.ps1` for explicit files or directories, optional recursion, CSV summaries and versioned JSON details. Reject malformed/unsupported files and report failures without silently omitting them.
- [x] Closed 2026-09-12: Replace the per-pixel PowerShell loop with a compiled C# histogram loop; preserve report fields and add collection progress reporting.
- [x] Closed 2026-09-12: Inventory both local production scene collections and retain separate dated CSV/JSON reports with per-file SHA-256 hashes. P1 complete; platform integration remains pending.

Validation 2026-09-12: PowerShell confirmed the 120-frame/12-level and 10-frame/4-level references; JSON export/readback passed. A synthetic odd-width masked frame confirmed padding exclusion and raw masked-pixel inclusion; a truncated mask was rejected. Reference CSV/JSON are in `output/scene-intensity/reference-2026-09-12`. The compiled parser's complete reports matched the original parser for both reference scenes and a two-row, odd-width masked fixture, including every per-frame histogram. Repeated module import passed. Platform validation remains pending.

### Collection findings — 2026-09-12

The initial read-only collection analysis used an in-memory compiled pixel loop after the original PowerShell loop proved too slow; persisted baseline export was pending at that stage. The compiled loop is now in the module and both collections have been rerun and exported successfully.

| Collection | Local source | Scenes | Stored frames | Scan + export |
|---|---|---:|---:|---:|
| DMD-Large | `scenes` | 2,416 | 73,731 | 20.4 s |
| Original DotCLK-Orig | `external/DotClk-Resources/Scenes` | 2,324 | 67,267 | 27.3 s |

Observed times are for this machine/run, not performance guarantees. Counts describe these local snapshots, not a fresh download verification.

| Used levels, including black | DMD-Large scenes | Original scenes |
|---|---:|---:|
| 2 | 107 | 106 |
| 3 | 95 | 88 |
| 4 | 1,290 | 1,241 |
| 5 | 48 | 14 |
| 6 | 16 | 16 |
| 7 | 21 | 21 |
| 8 | 46 | 46 |
| 9 | 112 | 112 |
| 10 | 132 | 132 |
| 11 | 169 | 169 |
| 12 | 377 | 377 |
| 13 | 2 | 1 |
| 16 | 1 | 1 |

No scenes use 1, 14, or 15 distinct levels. The most common value set is `0,1,3,15`: 1,257 DMD-Large scenes and 1,213 Original scenes. A four-level count does not imply the same values as the `scene_01` fixture (`0,5,8,15`). These findings do not establish a need for brightness remapping.

Persisted baselines (each directory contains `scene-intensity-levels.csv` and `scene-intensity-levels.json`):

- `output/scene-intensity/baseline-2026-09-12/DMD-Large`
- `output/scene-intensity/baseline-2026-09-12/DotCLK-Orig`

CSV/JSON readback verified both scene totals, frame totals, every distribution row above, matching per-file SHA-256 fields, and zero parsing errors. These are local output artifacts; retain/copy them when cleaning build output. Windows/macOS diagnostics, ESP32 integration, and all platform visual acceptance remain open under P2–P5. Playback and brightness behavior are unchanged.

```powershell
# Inspect two files without writing reports
.\scripts\Export-SceneIntensityLevels.ps1 -Path @(
  '.\firmware\dmdclock-esp32\build-qemu-waveshare\esp-idf\main\scene_00.scn',
  '.\firmware\dmdclock-esp32\build-qemu-waveshare\esp-idf\main\scene_01.scn'
)

# Export a reusable collection baseline; use a new directory for each run
.\scripts\Export-SceneIntensityLevels.ps1 -Path '.\scenes' -Recurse `
  -OutputDirectory '.\output\scene-intensity\baseline-2026-09-12'

# Reuse the parser with a future test file
Import-Module .\scripts\SceneIntensity.psm1
Get-ScnIntensityReport -Path 'C:\test-scenes\example.scn'
```

CSV contains path, filename, content hash, frame count, level counts and used values. JSON also contains histograms, frame details and errors. Frame indexes are zero-based. Reusing an output directory overwrites its two reports; source SCNs remain unchanged.

## Metadata decision — 2026-09-12

Store optional intensity summaries in file-specific entries of the existing `scene-metadata.json`, not a separate catalog or prefix entries. Each summary records SHA-256 of the measured SCN, its sorted used values, and frame count; derive the level count from the values. Original SCN files remain untouched. Detailed scene and per-frame histograms remain in the dated analysis reports.

Updated implementation order: enriched metadata and Waveshare 3.49B V2 first; other platforms later. Metadata generation/distribution, platform readers, runtime diagnostics, brightness mapping, and physical acceptance remain pending. Preserve existing brightness behavior on other platforms.

## User visual findings and mapping proposal — 2026-09-12

The saved P1 reports contain these exact two-level value pairs. Every listed scene contains black and one nonzero value:

| Source values | DMD-Large scenes | Original scenes |
|---|---:|---:|
| `0,1` | 4 | 4 |
| `0,3` | 37 | 37 |
| `0,4` | 1 | 1 |
| `0,15` | 65 | 64 |
| Total | 107 | 106 |

The user inspected these DMD-Large files in their viewer and reported the following output brightness values. Source values and stored frame counts come from the saved reports:

| Scene | Frames | Source values | User-observed viewer brightness |
|---|---:|---|---|
| `RD0256.scn` | 35 | `0,3` | `0,255` — off and on |
| `LAST_ACTION_HERO_010.scn` | 2 | `0,10,15` | `0,128,255` — off, middle, on |
| `APOLLO_13_003.scn` | 75 | `0,1,3,15` | `0,85,170,255` — four evenly spaced levels |

These observations support mapping by the sorted order of used source values rather than interpreting each source value as a fixed fraction of 15. The earlier description of source `3` as 20% was a linear-rendering assumption, not the output observed in the user's viewer. Viewer observations do not establish the original hardware's brightness transfer function or constitute ESP32 panel acceptance.

User suggestion and proposed implementation:

- Target both supported ESP32 panels: Waveshare 7 and Waveshare 3.49B V2. The decoder and metadata verification are shared; builds, cards, and panel acceptance remain target-specific.
- Generate enriched file-specific `scene-metadata.json` summaries from the saved reports, verified against source content; retain SHA-256, sorted used values, and frame count. Completed for the local DMD-Large metadata on 2026-09-12; distribution and firmware consumption remain pending.
- For scenes containing black and at least one nonzero level, map sorted used values to evenly spaced output brightness: `round(index * 255 / (levelCount - 1))`, with zero-based index. Thus two levels become `0,255`, three become `0,128,255`, and four become `0,85,170,255`. The earlier tentative four-level suggestion `0,64,128,255` is superseded by the observed equal spacing.
- Build one lookup table from the whole-scene summary and reuse it for every frame. Never normalize individual frames: a frame using only a subset must retain the scene's assigned brightness levels.
- User preference: always enabled on this model when valid matching metadata is available, without an activation toggle. Missing, invalid, or hash-mismatched metadata falls back to existing rendering and must not prevent playback.
- Apply mapping to scene pixels only, before overall brightness scaling; retain existing clock/text behavior and original SCN files. Keep raw diagnostics independent of mapped output.
- Mapping changes the original numerical spacing deliberately to match the inspected viewer. On two-level scenes it would brighten 42 scenes in each collection; `0,15` scenes would be unchanged.
- Settled 2026-09-12: reserve zero as an implicit black anchor for scenes without black, while keeping `usedValues` unchanged. Black-only data maps to zero; a sole nonzero value maps to 255. Round halves upward. Firmware implementation must check renderer precision so 8-bit brightness is not silently reduced incorrectly by the current 0–15 pipeline.

### First-target worklist

- [x] Closed 2026-09-12: Verify two-level value-pair distribution in saved reports and record the user's two-, three-, and four-level viewer observations.
- [x] Closed 2026-09-12: Enrich all 2,416 DMD-Large file entries in `scenes/scene-metadata.json`, preserving existing game information, prefix entries, and schema version.
- [ ] 2026-09-12: Distribute enriched strict-JSON metadata to both connected ESP32 scene collections and verify the copied artifact before flash.
- [ ] 2026-09-12: Implement verified whole-scene lookup mapping in the shared ESP32 decoder for both supported boards, including safe fallback and settled single-level/no-black behavior.
- [ ] Validate the three examples above, a frame containing only a subset of the scene levels, 12- and 16-level scenes, overall brightness scaling, unchanged clock/text, and missing/stale/malformed metadata.
- [x] Closed 2026-09-12: Build, flash, hard-reboot, and serial-check Waveshare 7 (COM4, MAC `3c:0f:02:c3:59:d8`) and Waveshare 3.49B V2 (COM5, MAC `28:84:85:92:b1:34`). Both mounted their installed TF cards, loaded metadata schema 1, indexed 2,416 scenes, and reached ready state. User panel acceptance remains open.
- [x] Closed 2026-09-12: Provisioned the enriched metadata to removable Disk 3 (`F:`). The provisioner validated all 2,416 SCNs and updated two managed artifacts; card and source metadata SHA-256 are both `40F227D48E167C7C9590D609D65035AC3E6E1E952EC513B8EDBEB6EB17ACED79`.
- [ ] 2026-09-12: Provision the second card, then reboot its board and confirm a `Verified intensity mapping` serial record before the brightness visual check.

JSON enrichment is complete; firmware and device changes remain pending. Broader P2–P5 tasks below remain open; they are not prerequisites for completing the first-target slice.

### Enriched JSON format and validation — 2026-09-12

Each file entry now has an optional `intensity` object with `sha256`, `frameCount`, `usedValues`, `mapping: "evenly-spaced-v1"`, and `outputValues`. The two arrays correspond position by position; output values are integer brightness levels from 0 to 255. Compute ranks using sorted used values plus an implicit zero anchor when absent; the implicit anchor is not added to the measured `usedValues`. Detailed histograms remain in the original analysis reports.

Validation passed before replacing metadata: all 2,416 current SCN SHA-256 hashes matched the saved DMD-Large JSON report, every entry had a matching report, and there were no report errors. All summaries were constructed from the matching report values. Existing metadata was compared after removing the added intensity objects and was identical, including prefix entries and schema version. All mappings were strictly ordered, bounded to 0–255, preserved black, and kept nonzero source values lit; all five scenes without black used the implicit anchor. The three user-inspected examples matched `0,255`, `0,128,255`, and `0,85,170,255`. Synthetic mapping checks covered black-only, sole-nonzero, and no-black multi-level inputs. Serialized JSON and on-disk readback matched the validated objects. Source SCNs and analysis reports were not modified. This is data validation only, not firmware or physical-panel acceptance.

## P2 — Shared metadata and Windows diagnostics

- [ ] Extend metadata generation to merge optional file-specific intensity summaries into the existing metadata while preserving game information and prefix entries. Use the measured file hash to identify the source content.
- [ ] Extend desktop and ESP32 metadata distribution, including scene installation and SD-card preparation, to carry the enriched existing `scene-metadata.json`.
- [ ] Extend the shared .NET metadata reader to consume optional summaries. Missing or stale intensity metadata means unknown intensity information and must not prevent playback; never present a hash-mismatched summary as current.

- [ ] Add equivalent raw-level analysis to the shared .NET core using the existing SCN reader; compare results against P1 reports for identical hashes.
- [ ] Show “Used intensity levels (including black)” and the sorted values in Windows scene diagnostics/reviewer. Include histogram details without changing playback.
- [ ] Verify the 12-level and 4-level references, black-only data, a single nonzero level without black, masks, and malformed input. Preserve original intensity spacing; do not copy the viewer's rank-based normalization.

## P3 — macOS parity (deferred)

Deferred until after the Windows and ESP32 work; not a gate for their initial acceptance.

- [ ] Expose the same shared diagnostics in the macOS ARM64 application.
- [ ] Compare JSON-equivalent counts and histograms for the same reference hashes on Windows and macOS; verify the UI labels on macOS.

## P4 — ESP32 parity

- [ ] Extend the ESP32 metadata reader to consume the same optional file-specific summaries on both supported boards. Missing or stale summaries must not prevent playback and must not be presented as verified intensity information.

- [ ] Add equivalent diagnostics for Waveshare 7 and 3.49B V2, reusing existing decoded frame data and bounded histogram storage rather than buffering complete scenes.
- [ ] Expose complete-scene counts through existing diagnostics/web tooling only after all frames are scanned; never label a partial playback scan as complete.
- [ ] Check both QEMU board configurations against P1 reference histograms, then flash/reboot each available physical board and verify playback, responsiveness, and displayed diagnostics. For 3.49B V2 also verify the proposed mapped brightness; other boards retain existing brightness. Broader board parity is deferred until after the first-target slice; record unavailable hardware as pending.

## P5 — Regression baseline and closure

- [ ] Maintain dated, SHA-256-identified reference reports and compare new files by content identity, not filename alone.
- [ ] Validate generated metadata and Windows/ESP32 reader results against both saved P1 collection baselines for matching hashes, used values, derived counts, and frame counts. Verify metadata absence and hash mismatch leave playback operational.
- [ ] Cover 4-level, 12-level, all-16-level, black-only, single-nonzero, masked, odd-width padded rows, truncated data and trailing-data cases.
- [ ] Record automated results separately from Windows/macOS UI and physical-panel acceptance, with closure date for each platform.
- [ ] Document any proposed brightness remapping separately for review; missing levels or a low whole-frame average are not sufficient evidence that correction is needed.
