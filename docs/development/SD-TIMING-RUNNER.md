# SD-backed playback timing comparison

The runner compares 200 identical scenes across old/new playback code on the
Waveshare 7-inch and 3.49B V2 boards, plus the latest frozen native Windows app.
It uses existing SD scene files and writes only dedicated timing logs.

## Run and resume

Use the pinned ESP-IDF Python environment (pyserial is required):

```powershell
$timingPython = 'E:\ai\.tools\esp-idf\v5.5.2\tools\python\v5.5.2\venv\Scripts\python.exe'
$timingOutput = 'output/esp32/sd-timing-20261016'
& $timingPython scripts/Compare-SdSceneTiming.py prepare $timingOutput
& $timingPython scripts/Compare-SdSceneTiming.py all $timingOutput
# After an interrupted controller, inspect its actual process before resuming:
& $timingPython scripts/Compare-SdSceneTiming.py resume $timingOutput
& $timingPython scripts/Compare-SdSceneTiming.py report $timingOutput
```

The per-run Windows file lock prevents a second live controller. Process state
is recorded in `runner-state.json`; a stale JSON/lock file alone does not mean a
process is live. The runner requests temporary system/display wakefulness while
it owns the test, then releases the request without changing power settings.

`scripts/Finish-SdTimingRun.py <output>` can watch the actual live process handle,
revalidate results after exit, run SD checkpoint recovery verification, restore
both boards again, and regenerate the final reports. Its outcome is saved in
`pipeline-finished.json`; incomplete results are never promoted to success.

## Controlled inputs

- Inventory every SCN on both cards and compare filename/content SHA-256 with
  Windows. Save missing, different, and extra files in `alignment.json`.
- Select 50 largest files, 50 fastest remaining scenes, 50 timing controls,
  and 50 representatives across games, with unique scene identities and a fixed
  seed. Include the pilot scenes when available. Freeze `selected-200.json`.
- Preserve the original parser, decoder, and scheduling logic. Old builds use
  stable panel/board/SD drivers, long-filename support, and a diagnostic selector;
  they are hybrids, not exact historical firmware performance references.
- Use Basic orange, brightness 100%, glow 50%, 24-hour clock, no seconds/info,
  automatic playback off, and background schedule/MQTT/playback logging off.
- The current run uses epoch 1704067200 on ESP32 with its verified CET timezone,
  matching Windows' virtual 2024-01-01 01:00:00+01:00 clock. Elapsed playback
  clocks remain monotonic. The PC's real system time is not changed.

Do not rebuild a frozen run after accepting measurements: create a new run when
measurement firmware or native timing/rendering code changes. The initial SD
qualification rejected stale selection and a missing long-filename capability
before any hardware logs were accepted; those attempts remain under `attempts/`.

## Timing and SD logging

The diagnostic selector loads the selected SD file before the timed window,
verifies its loaded bytes, and invalidates the reader's same-index cache when
the filename changes. This keeps storage/parse time separate from playback.
The display's normal selection call then uses the original cached-scene path.
The loaded bytes are hashed again after completion.

Frame/step timestamps stay in RAM while a scene plays. After completion, the
probe writes a JSONL temporary file, flushes/syncs/closes it, and renames it into
`/sd/dmd/logs/timing/<run-id>-<stage>/<oldest|latest>/<case-id>-rN.jsonl`.
Only a committed footer is accepted. The collector checks file length and
SHA-256 and independently validates every frame/delay pair against the SCN.

USB carries commands, inventory metadata, and result logs; SCN bytes are not
uploaded. On resume, the frozen full inventory is retained, completed host logs
are revalidated, committed SD logs can be recollected, and each newly played
scene is checked against loaded bytes. Scene files and normal playback logs
are not overwritten. Each board is restored to its verified pre-test flash
snapshot on handled exit; `restore-required.json` persists until successful.

Windows runs one visible isolated native app, using its normal timer and
renderer, an authenticated loopback-only diagnostic load/export extension,
and in-memory callback traces. Library file watching is disabled in this copy
to avoid rescan interference; startup scanning/branding finishes before tests.

## Coverage and interpretation

Qualify with ten scenes (50 target cases), then run 200 scenes (1,000 initial
cases). Repeat flagged scenes twice on every target. A repeated duration
difference requires more than both 5% and 50 ms in the same direction in at
least two of three pairs; repeated skipped steps also count as a difference.
The pair summary reports confirmed duration differences and repeated skipped
frames separately. Those counts can overlap; skipped frames alone do not
establish shorter playback duration.
The full matching library runs only if the completed sample finds no confirmed
difference and no input collection mismatch requires alignment first.

ESP32 measures first decode to completion; Windows measures session start to
completion. Loading is reported separately. Per-step render timestamps are
software submissions, not optical panel measurements. Starts are normalized
per scene, not synchronized across physical screens. Results cover this Basic
configuration; a selected sample is not a claim about all untested scenes.

Output:

- `report.html`: searchable/sortable comparison with duration bars.
- `report.md`: complete matrix, confirmed differences, and recommendations.
- `measurements.csv`: scene/target/repetition durations and timing inputs.
- `step-timings.csv`: observed versus expected step timing and omitted steps.
- `esp32-pacing-reference.json`: review-only per-step medians for the stable
  7-inch v1.8.0 target; it does not configure or change playback.
- `results/`: immutable collected JSONL and native callback traces.
- `summary.json`, `comparisons.json`, `alignment.json`: machine-readable results.
- `recovery-check.json`: cached-log recovery after firmware changes, without
  replaying the case, followed by both firmware restorations.
- `completion-audit.json`: independent coverage, raw-evidence, source/hash,
  expansion-gate, recovery, and restoration checks. Generate after the pipeline
  finishes with `python scripts/Audit-SdTimingRun.py <run-directory>`; it exits
  nonzero when any required evidence remains incomplete.

Reports must expose incomplete cases and coverage gaps. A single global speed
factor is not assumed. Any proposed compatibility mode remains a separate
playback change for review after the evidence is available.
