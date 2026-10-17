# Playback timing investigation

## Approved Windows 100 ms policy (2026-10-17)

The user watched `LAST_ACTION_HERO_061.scn` ten times on each platform and
rejected the Windows 10 ms playback as too fast. Windows now plays explicit
10 ms regular delays at 100 ms and uses a 100 ms missing/zero fallback.
Other explicit regular delays and all first/last holds remain unchanged.
The scene files, frozen references, and ESP32s remain unchanged. This approved
visual preference supersedes the earlier instruction to retain Windows 10 ms;
it does not establish original pinball-machine timing.

The effective Windows target for this sequence is 13.700 s, compared with
its unchanged 1.370 s stored timeline. Diagnostics distinguish file timing
from the playback override. See [current Windows behavior](WINDOWS-FRAME-PACING.md#current-approved-timing-policy-2026-10-17).

- [ ] Obtain user visual acceptance of the new 100 ms Windows candidate.
- [x] Validate the 100 ms policy: 209 core/API and three headless UI tests;
  standalone win-x64 publish; focused native override/fallback/control captures
  with complete coverage, zero skips, and unchanged real scene/manifest hashes.
  [Validation evidence](../../output/timing/windows-100ms-20261017/validation.json).
- [ ] Remeasure Standard50 for the new policy in a separate evidence directory,
  with effective expectations recorded independently of frozen file timings.

## Current findings and TODO (2026-10-17)

The pre-override three-platform findings and all 50 scene timings are retained in
[Playback platform differences](PLAYBACK-PLATFORM-DIFFERENCES.md).

- [x] Complete Standard50-v1 on Windows and both ESP32s: 450 measurements,
  plus 90 qualification captures, with frozen scene/build identities.
- [x] Implement the user-requested Windows frame pacing: full hold after
  submission, no catch-up skips, and 10 ms missing/zero regular timing fallback.
- [x] Validate the candidate: 203 core/API tests and three headless rendered UI
  tests; Windows native captures remain separate from physical visual acceptance.
- [x] Remeasure all 50 scenes three times on Windows and compare with the
  earlier 300 ESP32 captures using matching scene hashes.
- [x] Confirm complete coverage: current Windows and both ESP32s each observe
  all 11,937 steps. Windows skips fall from 5,677 to zero.
- [x] Record remaining differences: 20 / 50 against each ESP32, all explicit
  10 ms scenes. Median actual/file-duration ratios are Windows 1.076x,
  ESP32 7 inch 7.689x, and ESP32 3.49 inch 7.676x.
- [x] Record the other 30 scenes as below the agreed confirmation threshold;
  separate the eight changed-fallback scenes from authored timing comparisons.
- [x] Verify the earlier raw captures, fixed reference, and 200-scene comparison
  remain unchanged; keep fresh Windows results in a separate run directory.
- [ ] Obtain user visual acceptance of current Windows pacing in windowed and
  fullscreen playback; software coverage does not establish optical presentation.
- [ ] Profile per-step processing and scheduling on both ESP32s for the 20 short
  delay scenes; isolate the source of their longer duration without changing
  playback speed, scene data, NTP, system clocks, or saved settings.
- [ ] Compare representative short-delay scenes with a trusted original player
  or external timing reference before choosing further playback corrections.
- [ ] Add version-specific fallback expectations to the reusable comparison
  runner while keeping Standard50-v1 bytes and authored holds frozen. The
  current strict validator expects the earlier 100 ms fallback for eight scenes.
- [ ] Decide whether missing-timing fallback should be aligned across platforms;
  any ESP32 playback change requires its own implementation and validation.

Fresh comparison: `output/timing/windows-vs-recorded-esp32-20261017/`.
Earlier Standard50: `output/timing/standard50-v1-20261017-final/`.
Confirmation requires both >5% and >50 ms, same direction in at least two of
three repetition pairs. Publication remains a separate task.

## External timing evidence (2026-10-17)

The goal is playback faithful to the original pinball machine. Keep three
different timing references separate:

| Reference | Established evidence | Status |
|---|---|---|
| Stored SCN timing | Scene-authored first, regular, and last delays; the frozen manifest records these values. | Known file values, not independently verified machine timing. |
| Original DotClk behavior | Firmware interprets scene delays using elapsed milliseconds and advances at most once per loop. | Source verified; physical Teensy timing remains unmeasured. |
| Original pinball-machine timing | A matched animation sequence with independently established presentation timestamps. | Unverified for the investigated scenes. |

### Sources for fact checking

The firmware and editor links below pin the reviewed source revisions. The
Modern Hackerspace PDF link follows `master`; the relevant section is "Main
Editor", item 6, on PDF page 32 (zero-based page index 31).

| Source | What it establishes | What it does not establish |
|---|---|---|
| [Original DotClk playback loop](https://github.com/sigmafx/DotClk/blob/5ed33a570f9bbec6e891ae3908a4018e49ebca68/DotClk.ino#L408-L426) | Compares elapsed `millis()` with the scene delay using strict `>`, advances once per loop, and adds the delay to its previous timing reference. | No single animation FPS setting or measured loop period; processing capacity can extend playback. |
| [Original scene delay selection](https://github.com/sigmafx/DotClk/blob/5ed33a570f9bbec6e891ae3908a4018e49ebca68/Scene.cpp#L179-L198) | Returns the stored first, regular, or last delay directly; zero regular delay passes through unchanged. | No original-firmware 10 ms or 100 ms fallback for zero regular delay. |
| [Original SceneEditor](https://github.com/sigmafx/DotClk-Support/blob/5481e3affde2946361e9115aa53c1a04b35fb6c0/SceneEditor/SceneEditor/Form1.cs#L30-L69) | Saves the delay entered by the scene author in the storyboard. | No proof that the entered value was measured from the pinball machine. |
| [Modern Hackerspace build and usage instructions, PDF page 32](https://gitlab.com/modernhackerspace/dmdclock/-/raw/master/DMD%20matrix%20build%20and%20Instructions.pdf#page=32) | Describes manually adjusting milliseconds between frames to make animation look realistic. | No universal machine-authentic delay and no verification of this library's scene timings. |

These sources establish the clock's interpretation of delays, not the original
machine's intended timing. In particular, a stored 10 ms delay requests a
nominal 100 animation steps per second; neither a display refresh rate nor an
observed hardware bottleneck establishes that this is the machine's cadence.
The original firmware's accumulated timing reference also differs from the
current Windows full-hold-after-submission policy. Do not describe those
policies as identical.

For `LAST_ACTION_HERO_061.scn`, the [three-platform comparison](PLAYBACK-PLATFORM-DIFFERENCES.md#findings)
records 137 steps at 10 ms, requesting **1.370 seconds**, versus measured medians
of **1.475 seconds** on Windows, **10.541 seconds** on the 7-inch ESP32, and
**10.536 seconds** on the 3.49-inch ESP32. All steps are observed. None of these
durations is yet verified as the original machine's duration.

### Remaining reference investigation

- [x] Review the original clock's timing logic, editor serialization, and the
  supplied Modern Hackerspace instructions; retain fact-check links above.
- [ ] Trace provenance for all 20 confirmed differing scenes: scene name, game,
  upstream repository/revision/file link, SHA-256 comparison with the frozen
  fixture, and any documented origin of its delay. Mark missing provenance
  explicitly; a matching filename alone is insufficient.
- [ ] Obtain timestamped references for `LAST_ACTION_HERO_061.scn`,
  `APOLLO_13_009.scn`, and `RD1241.scn`, plus the matching control `RD0005.scn`.
  Prefer original-machine captures or timestamped execution of the matching
  game ROM at normal speed. An original DotClk capture establishes clock
  compatibility only unless independently matched to the machine.
- [ ] Accept a reference only after matching the actual animation sequence.
  Record its URL/artifact, game and ROM revision (or explicitly unknown),
  playback speed, capture rate/timebase, start/end and intermediate timestamps,
  repeated frames, sequence differences, and timing uncertainty. Reject edited,
  speed-adjusted, or ambiguous clips as proof of intended duration.
- [ ] Keep author-selected opening/closing holds separate from the machine
  animation; report both animation-only and complete-scene durations.

### Correction proposal for review before code changes

Establish the intended timeline first, then make playback follow that verified
timeline. External evidence does not yet establish machine-authentic delays.
The later user-approved Windows 100 ms policy above is a visual preference.

1. Retain explicit scene delays provisionally, except for the approved Windows
   10 ms regular-delay override above. Do not apply a global slowdown
   derived from ESP32 duration, or treat the existing missing/zero fallback as
   an original-machine timing value.
2. Where matched machine evidence confirms SCN timing, retain that timing and
   investigate the ESP32's excess processing time. Profile decoding,
   composition, panel submission, buffer waits, and scheduling separately
   before selecting an optimization.
3. Where matched machine evidence contradicts SCN timing, document the frame
   correspondence and discrepancy, then propose a correction limited to the
   verified scenes. Unsupported scenes remain explicitly unverified.
4. Preserve the current Windows requirement to show every step with its full
   hold. If the verified timeline conflicts with that requirement, describe
   the conflict and proposed behavior for review before implementation.

The original external-reference stage updated investigation documentation only.
The later Windows policy above is separately user-approved. Playback APIs, settings,
scene format/data, firmware, and application code remain outside its scope;
profiling changes, hardware runs, and playback corrections are follow-up work.

Acceptance for a subsequent correction requires directly checkable timing
sources and matched sequences for every claimed intended duration. Preserve
scene hashes and complete step coverage, then remeasure Standard50 three times
per platform. Retain the existing confirmation rule: both >5% and >50 ms, same
direction in at least two of three repetition pairs. Record version-specific
fallback expectations separately from the frozen manifest. Verify visible
playback separately from software timestamps; agreement between platforms
alone is not proof of machine-authentic timing.

## Original pilot / 200-scene scope (historical)

Compare identical SCN bytes on the 7-inch ESP32, 3.49B V2 ESP32, and latest
local Windows app at 1x in Basic orange. Each ESP32 runs earliest playback
code with its stable panel driver, then v1.8.0. Historical builds adapted to
new panel drivers are hybrids, not exact historical performance references.
That investigation included no playback fixes and no Teensy. Run locally
without AI services. The later authorized Windows-only change is recorded above.

## Pilot: ten scenes

- [x] Freeze ten fixtures, source revisions, settings, and instrumentation diffs.
- [x] Identify both USB devices and verify full backups before flashing.
- [x] Build isolated old/new snapshots for each panel and current native Windows.
- [x] Run the boards and Windows concurrently; save every completed case.
- [x] Independently validate SCN hashes and frame/delay sequences.
- [x] Compare duration, skipped frames, and render-submission timestamps.
- [x] Restore both devices to their pre-test flash contents and close test apps.
- [x] Record results, limitations, and an ETA based on measured throughput.

## SD-based 200-scene run (authorized)

- [x] Select a reproducible representative 200-scene manifest.
- [x] Implement SD-backed scene selection in isolated old/new builds for both boards.
- [x] Buffer timing records in RAM and commit dedicated SD logs after each scene.
- [x] Implement USB log collection with file length/SHA-256 verification.
- [x] Implement a single-process isolated native Windows batch and callback traces.
- [x] Inventory both SD cards and report missing/different files against Windows.
- [x] Qualify SD loading, logging, and collection on the ten pilot scenes.
- [x] Validate per-case resume and SD checkpoint recovery; use scene-aware timeouts.
- [x] Repeat significant differences and failures to three total measurements.
- [x] Export raw traces, CSV, and Markdown reports for offline aggregation.
- [x] Report evidence-backed alignment suggestions without changing playback behavior.
- [x] Evaluate full-library expansion: not triggered because sample differences were confirmed.

Runner: `scripts/Compare-SdSceneTiming.py`; native adapter:
`scripts/TimingNativeBatch.py`; diagnostic C/H templates:
`scripts/esp32/tests/fixtures/sd_timing_probe.*`.
Historical 200-scene run directory: `output/esp32/sd-timing-20261016/`.
Full inventory: all 2,416 SCN files match on both cards and Windows. SD
qualification: all 50 target cases passed. The 200-scene run completed with
1,940 validated measurements, including two extra repetitions of all 94 flagged
scenes on every target. The completion audit and physical SD recovery passed;
both boards were restored to their pre-test flash snapshots. See
[results and recommendations](SD-PLAYBACK-TIMING-RESULTS.md) and
[runner instructions](SD-TIMING-RUNNER.md).
All code changes to playback/app/board implementations are confined to copied
diagnostic builds. SCN files on the cards are read only; only dedicated test
logs are written. The old build remains explicitly a stable-driver hybrid.

## Interpretation of the earlier runs

Compare Windows with each ESP32 version, old/new on the same board, and boards
at the same version. Separate scene duration from skipped frames and rendering
capacity. Software render completion is not proof of optical presentation.
The larger run is now authorized. Expansion beyond 200 scenes is conditional
on finding no confirmed difference; report any coverage gaps explicitly.

## Pilot evidence

Run: `output/esp32/timing-pilot/20261016-pilot10/`.
See its `report.md`, `summary.json`, `comparisons.json`, and `measurements.csv`.
All 50 primary cases were captured. Each hardware snapshot processed the same
651 scheduled steps (2,604 validated hardware records across four snapshots).
Apollo took 10.867-11.292 seconds on ESP32 versus 1.475 seconds on Windows,
which skipped 73 overdue frames. The other nine Windows cases skipped none.
Old/new differences were at most 0.26% on the 7-inch and 3.91% on the 3.49-inch
board in this single-pass pilot; repeats are required for statistical claims.

The first attempt caught an omitted mutex in the new test adapter before any
hardware scene measurement. The adapter was corrected, rebuilt, and rerun;
failed-attempt logs are preserved. No production playback source was changed.

Measured playback totals: Windows 70.506 seconds; each ESP32 build 81.052-82.011
seconds for these ten scenes. For 200 scenes with the same mix, both ESP32
versions would require about 55 minutes of playback per board, with the boards
running in parallel. This excludes USB staging, flashing/restoration, and
repeats; compute a better estimate from the actual 200-scene manifest after
the larger runner implements staging. Earlier estimates were conservative.
