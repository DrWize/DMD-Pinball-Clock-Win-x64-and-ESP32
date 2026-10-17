# Windows frame pacing candidate

## Current approved timing policy (2026-10-17)

After watching ten plays on all three devices, the user rejected Windows'
10 ms motion as too fast and approved 100 ms playback instead. Windows now
maps explicit **10 ms regular delays to 100 ms**, and missing/zero regular
timing also uses **100 ms (10 FPS)**. Other explicit regular delays and all
explicit first/last holds retain their file values. This is a user-approved
playback policy, not a verified reconstruction of original pinball timing.

The SCN files and ESP32 firmware are unchanged. Windows still presents every
step, starts its full hold after submission, and never skips to catch up.
For `LAST_ACTION_HERO_061.scn`, the effective 1x target is now **13.700 s** for
137 frames; its stored 10 ms value and original 1.370 s file timeline remain
intact. Debug speed scaling applies after the playback policy.

Diagnostics retain the original `fileFps` (100 for a stored 10 ms delay), report
an effective target of 10 FPS at 1x, and mark the change with `timingAdjusted`,
`timingSource: "override"`, and `timingLabel: "10 ms played at 100 ms"`.
Expected/adjusted durations describe effective playback. Prior measurements
and Standard50-v1 remain historical evidence; do not rewrite their timings.

Local build: `output/candidates/windows-100ms-1.9.0-1/DmdClock.App.exe`.
The user accepted the Windows appearance on 2026-10-17. This does not establish
machine-authentic timing or a new full-library timing benchmark.

Validation: `dotnet test DMDClock.sln -c Release --no-restore` passed 209
core/API tests and three headless UI tests; self-contained win-x64 publish
succeeded. Focused native results are in
[`output/timing/windows-100ms-20261017/validation.json`](../../output/timing/windows-100ms-20261017/validation.json).
One run each observed every step with zero skips: Last Action Hero took
13.819 s against the effective 13.700 s target (minimum recorded gap
100.045 ms); the unchanged 90 ms `RD0005.scn` control took 2.726 s against
2.700 s; a clearly named synthetic zero-delay copy took 13.798 s against
13.700 s. The frozen manifest and real scene hashes were verified unchanged.
This focused check is not a new Standard50 run or physical visual acceptance.

## Earlier 10 ms candidate (historical)

Local candidate: `1.9.0-frame-pacing.1`, 2026-10-17. The remaining sections
record its superseded behavior and measurements.

## Behavior at 1x

- An explicit 10 ms regular frame delay remains 10 ms.
- Missing storyboards and zero regular delays now use 10 ms (100 FPS target),
  replacing the previous 100 ms (10 FPS) fallback. Diagnostics and compatibility
  warnings report the new fallback.
- Other nonzero delays and explicit first/last holds retain their file values.
- Each callback advances at most one playback step. A late callback never skips
  intermediate steps to catch up with elapsed wall time.
- Each frame's full hold starts after the app submits that frame. The final
  frame must finish its hold before scene completion. Clock-only overlay updates
  do not restart the animation hold.
- Active animation uses a timer-queue wakeup at a requested 1 ms interval,
  posting at most one pending callback to the UI. Idle and paused operation
  use the existing 16 ms dispatcher timer. A paired Windows timer-resolution request is held only
  during active animation and released when idle, paused, or the window closes.
  See [Microsoft's timer-resolution contract](https://learn.microsoft.com/windows/win32/api/timeapi/nf-timeapi-timebeginperiod).
- Existing explicit debug speed controls still scale frame delays. Normal
  playback remains 1x.

This is a **minimum software hold**, not a hard real-time 100 FPS display lock.
UI scheduling and rendering can extend it; the candidate deliberately permits
a longer scene rather than skipping frames. A display refresh or optical
presentation is not measured by these diagnostics. Windows may also reduce
timer precision for an occluded/minimized window.

## Validation

`dotnet test DMDClock.sln -c Release --no-restore`: 203 core/API tests and three
rendered headless UI tests pass. Cases include a one-second stalled callback,
explicit/missing/zero timing, full hold after submission, final-frame hold,
pause/resume, special blank holds, and debug speed changes.

Focused native API results are separate from the frozen reference run:
`output/timing/windows-frame-pacing-20261017/validation.json`.
Two original scenes and one clearly named synthetic zero-delay copy ran three
times each, all with every step observed and zero catch-up skips. Raw traces,
the copied source hashes, isolated settings, and the validation script are in
the same directory. No ESP32 connection is used by this validation.

For `LAST_ACTION_HERO_061.scn`, all 137 steps were observed in each repetition;
the previous Windows reference observed 56, 59, and 67. In this native session,
the new runs took 1,469.54–1,511.51 ms versus the file's 1,370 ms target. The
minimum recorded gaps were 10.03–10.11 ms. The synthetic zero-delay copy took
1,462.07–1,469.78 ms, also observing all 137 steps on every repetition.
The 90 ms scene took 2,721.14–2,725.53 ms versus its 2,700 ms target, observing
all 30 steps each time.

Step preservation and minimum holds are verified; a mathematically exact
10 ms sustained cadence is **not** established. The initial dispatcher-timer
implementation took roughly 2.1 seconds for the 1.37-second scene, even with
a scoped resolution request. Replacing that active-playback timer path with
coalesced timer-queue wakeups removed most of the additional scheduling delay.
Composition and UI scheduling still add some time to the full per-frame holds.

## Full Standard50 comparison against recorded ESP32 results

The later run at `output/timing/windows-vs-recorded-esp32-20261017/` contains
150 fresh Windows measurements against 300 saved ESP32 measurements. All
11,937 Windows steps were observed, with zero skips. All 20 explicit 10 ms
scenes still have confirmed duration differences against each board; the other
30 scenes do not exceed the agreed confirmation threshold. For the 10 ms
group, median per-scene actual/file-duration ratios are Windows 1.076,
7-inch ESP32 7.689, and 3.49-inch ESP32 7.676. All prior raw evidence and the
reference manifest were verified unchanged. See that run's `report.md`,
`scene-comparison.csv`, raw JSON, and source-hash provenance.

Eight reference scenes have zero regular timing. Their fixed manifest retains
the original 100 ms fallback expectations; candidate-specific 10 ms
expectations are recorded separately in `candidate-timing-expectations.json`.
Their explicit long holds remain unchanged.

## Try the local candidate

Close the existing Windows app, then run from the repository root:

```powershell
.\output\candidates\windows-frame-pacing-1.9.0-1\DmdClock.App.exe
```

The runnable candidate uses the normal Windows app settings and library. It is
not a published release and does not replace an installed executable.

Build it again without changing release metadata:

```powershell
dotnet publish .\src\DmdClock.App\DmdClock.App.csproj -c Release -r win-x64 --self-contained true -p:Version=1.9.0-frame-pacing.1 -p:InformationalVersion=1.9.0-frame-pacing.1 -o .\output\candidates\windows-frame-pacing-1.9.0-1
```

The prior Standard50 and 200-scene evidence, reference manifest, scene files,
ESP32 firmware, Wi-Fi, NTP, and system clocks are untouched by this change.
Run any later cross-platform comparison in a new run directory; do not resume
the frozen old-build run with this candidate.
