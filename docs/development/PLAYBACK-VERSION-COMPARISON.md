# Playback timing across versions

Investigation: 16 October 2026. Windows animation playback only; no playback fixes applied.

Follow-up: the [ESP32 reference and native Windows comparison](ESP32-PLAYBACK-TIMING-COMPARISON.md)
reproduces Windows finishing some scenes much sooner than the physical ESP32.
That cross-platform scheduling difference is separate from the unchanged
Windows core timing across releases described below.

## Result

**No acceleration was found between the initial Windows implementation, v1.8.0,
and the local v1.9.0 candidate at its default 1× speed.** All 4,864 deterministic
results matched across the three independently compiled core snapshots. These
cover all 2,416 local real scenes plus synthetic timing cases.

The original **DotClk v1.14 firmware (2022)** has different timing behavior.
Its loop advances at most one frame per iteration. Windows catches up to the
scene timeline in one callback, potentially skipping intermediate frames.
Consequently, Windows can finish high-frame-rate scenes sooner than an original
device whose loop cannot keep up. That behavior was already present in the
first Windows commit; it was not introduced by a subsequent Windows release.
This is a source and timing-model finding, not a physical Teensy measurement.

## Available history

| Baseline | Identifier | Date | What was tested |
| --- | --- | --- | --- |
| Original DotClk firmware v1.14 | `external/DotClk`, `5ed33a5` | 2022-07-05 | Reviewed source and explicitly modeled timing logic |
| Initial Windows implementation | `186a572` | 2026-07-23 | Compiled core, deterministic playback, wall-clock pacing |
| First Windows tag | `v1.0.0` | 2026-07-25 | Reader/session blob identity and main timer inspection |
| Latest local release tag | `v1.8.0`, `4145cb2` | 2026-09-12 | Compiled core, deterministic playback, wall-clock pacing |
| Latest committed checkout | `497288c` | 2026-09-13 | Reader/session blob identity and main timer inspection |
| Local candidate | Uncommitted v1.9.0 | Working source at investigation time | Compiled core, deterministic playback, wall-clock pacing |

The Windows repository is not shallow, and its initial commit has no parent.
No older Windows implementation was found in local history or the inspected
archives/copy. The original DotClk checkout is shallow: 2022 is an available
upstream snapshot, not a claim about the first upstream version ever written.

All 19 version tags were inspected: v1.0.0, v1.1.0-plasma.1,
v1.1.0-plasma.2, v1.2.0, v1.3.0–v1.3.4, v1.4.0–v1.4.2, v1.5.0,
v1.6.0, v1.7.0–v1.7.2, and v1.8.0. The `DMD` and scene-pack tags are
additional non-version tags.

## Changes that affect timing or its appearance

| First occurrence | Behavior | Implication |
| --- | --- | --- |
| Initial Windows commit `186a572` | `Advance` uses `while (now >= deadline)` and accumulated deadlines | Late callbacks can skip multiple steps; the scene keeps its intended duration |
| Initial Windows commit `186a572` | Regular delay 0 becomes 100 ms; absent storyboard gets a 100 ms fallback | Already present in the earliest code; no later default speed increase |
| Initial Windows commit `186a572` | First storyboard is selected; special first/last holds become explicit playback steps | Same throughout committed Windows history |
| `f43613a` (2026-07-24) | Scene Reviewer added with a 33 ms timer; main display remains 16 ms | Reviewer and main window may show different numbers of intermediate frames |
| `3f8ffe8` (2026-07-26) | Animated plasma palette and effect clock | Changes visible color motion and rendering work, not SCN frame delays |
| `1055c52` (2026-08-03) | Hot-core rendering | Changes rendering work; no frame delay or playback scheduler change |
| Local v1.9.0 | Playback uses `Stopwatch`-based monotonic time instead of UTC | Prevents wall-clock adjustments affecting progression; 1× schedule matches historical code |
| Local v1.9.0 | Debug speed 0.1×–4×; default 1× | Explicit speed changes can accelerate playback; speed is initialized to 1 and disabling debug restores 1× |
| Local v1.9.0 | Library duration estimates use playback steps | Displayed estimates can change without actual scene speed changing |

Git history for `ScenePlaybackSession.cs` and `ScnReader.cs` contains only their
initial addition among committed revisions. Their Git blob IDs are identical
across the initial commit, all version tags, and HEAD. The main window's 16 ms
timer is also present in all of those snapshots. Source review found no change
to scene creation, completion, or pause/resume that shortens the 1× schedule.
Clock dwell time, animation gaps, palette animation, and per-scene playback
duration are separate behaviors.

## Executed Windows tests

The probe compiles copied source into separate Release executables without
starting the desktop application or reading installed settings. All three
executables receive the same manifest of SHA-256-verified input files.

- 2,416 real scenes at both 16 ms and 250 ms callback cadences: 4,832 cases per snapshot.
- Eight synthetic fixtures at 1, 16, 33, and 250 ms cadences: 32 cases per snapshot.
- Fixtures cover regular timing, zero-delay fallback, absent storyboard,
  first/last holds, blank holds, fast frames, one frame, and multiple storyboards.
- Every case checks completion against an independent duration formula and
  hashes the timestamped frame-index/blank/layer/completion/change trace.
- Pause/resume remaining time, restart deadlines, and manual next/previous
  checks pass in every snapshot; the local candidate's default speed is 1×.

**14,592 deterministic runs passed, with zero cross-version differences.**
These tests compare selected frame states; they do not measure monitor refresh
or visible presentation. The identical reader source and shared file hashes
also rule out different input timing bytes in this controlled comparison.

Three real scenes were additionally paced at approximately 16 ms using actual
elapsed time. Historical snapshots use UTC, matching their app calls; the local
candidate uses its actual `PlaybackClock.Now`. The following are single samples,
not a performance benchmark or a statistically significant ordering:

| Scene | Intended duration | Initial Windows | v1.8.0 | Local v1.9.0 |
| --- | ---: | ---: | ---: | ---: |
| APOLLO_13_009.scn | 1470 ms | 1484.571 ms | 1478.365 ms | 1478.375 ms |
| LAST_ACTION_HERO_001.scn | 1544 ms | 1559.238 ms | 1549.394 ms | 1544.238 ms |
| LAST_ACTION_HERO_006.scn | 1600 ms | 1610.957 ms | 1608.398 ms | 1614.148 ms |

The small timing differences are consistent with callback/clock sampling
granularity, rather than a changed speed multiplier. APOLLO has jumps of more
than one frame in every snapshot, demonstrating the longstanding catch-up
behavior. These runs do not include Avalonia rendering or its dispatcher.

## Earlier original firmware comparison

The separate Python model transcribes `Scene.cpp`'s `NextFrame`, `Eof`, and
`GetFrameDelay`, plus the timing condition in `DotClk.ino`. It verifies the
reviewed source revision and saves source hashes. It excludes SD access,
graphics, interrupts, and real hardware costs. Loop cadence is a hypothetical
input; **16 ms is not a measured Teensy loop period**.

| Case at a hypothetical 16 ms loop | Windows deterministic duration | Original firmware model |
| --- | ---: | ---: |
| Five frames, 100 ms regular delay | 512 ms | 512 ms |
| Five frames, 5 ms regular delay | 32 ms | 80 ms |
| Five frames, delay 0 | 512 ms | 80 ms |
| Five frames, 50 ms first hold and 75 ms last hold | 528 ms | 640 ms |
| APOLLO_13_009.scn | 1472 ms | 2352 ms |
| LAST_ACTION_HERO_001.scn | 1552 ms | 1584 ms |
| LAST_ACTION_HERO_006.scn | 1600 ms | 1616 ms |

The 32 modeled cases and four independent sanity assertions passed. Source
differences explaining these results are:

- Original uses a single `if` per loop and strict `>`; Windows catches up in a
  `while` using `>=`. A slow original loop can extend a fast scene, while Windows
  can omit intermediate frames and retain total duration.
- Original returns delay 0 unchanged; Windows substitutes 100 ms. Windows can
  therefore be slower for zero-delay scenes. There is no universal acceleration.
- Original's last special hold goes through an additional state and waits a
  regular interval before closing; Windows ends after its explicit final hold.
- Original overwrites storyboard settings as it reads them, effectively using
  the last; Windows uses the first. All 2,416 current real scenes have exactly
  one storyboard, so this difference does not affect this library.

In this library, 29 scenes have nonzero regular delays below 16 ms, 198 have
regular delay 0, and 1,285 have a final hold. Hardware comparison is needed to
quantify the real-world effect of the original loop and rendering costs.

## Reproduction and evidence

From the repository root:

```powershell
python scripts/Compare-PlaybackVersions.py
python scripts/Compare-OriginalDotClkTiming.py <evidence-directory-printed-by-first-command>
```

Requires Python, Git, .NET 10, the local scene library, and the reviewed
`external/DotClk` snapshot for the original model. Builds and JSON evidence go
under a new ignored `output/verification/playback-comparison/<timestamp>/`
directory on each run. No installed configuration is changed.

Evidence for this report is in
`output/verification/playback-comparison/20261016T192840245782Z/`:
`summary.json`, `version-inventory.json`, `scene-manifest.json`, per-snapshot
`results.json`, `source-hashes.json`, `build.log`, and
`original-dotclk-model.json`.

Still unproven: original hardware playback duration, native Windows visible
presentation across versions, and any historical changes to the user's scene
files/settings. No Windows release commit could be identified as introducing
acceleration because none was reproduced. No production code, settings, or
original SCN files were changed by this investigation.
