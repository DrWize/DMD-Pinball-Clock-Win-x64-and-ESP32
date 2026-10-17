# Local timing pilot

Use `scripts/Compare-SceneTiming.py` with the ESP-IDF Python environment, which
includes pyserial. No AI calls, hosted services, or installed Windows settings
are used. Results and local device backups go into the specified ignored output
directory. Backups can contain credentials and should remain local.

```powershell
$timingPython = 'E:\ai\.tools\esp-idf\v5.5.2\tools\python\v5.5.2\venv\Scripts\python.exe'
$timingOutput = 'output/esp32/timing-pilot/20261016-pilot10'
& $timingPython scripts/Compare-SceneTiming.py prepare $timingOutput
& $timingPython scripts/Compare-SceneTiming.py run $timingOutput
& $timingPython scripts/Compare-SceneTiming.py report $timingOutput
```

`prepare` requires a new directory and prepares the ten fixed real SCN files,
isolated source copies, a native Windows executable, and four hardware images.
`build` retries compilation in an existing prepared source directory.
`run` verifies the inspected USB identities, backs up both boards, runs three
workers concurrently, and restores the boards in each hardware worker's finally
block. Each board's old/new firmware is sequential. Do not unplug devices or
close the controlling process while flashing. An unexpected process termination
requires `restore <output>` before further testing. A disconnected device can
only be restored after reconnection.
The `restore-required.json` marker persists until restoration succeeds. Retrying
`run` retains a completed ten-scene Windows capture and reruns the ESP32 phases;
general per-scene resume is not implemented in this pilot.

The 7-inch adapter is COM4 / USB serial 5B3E087595. The 3.49B V2 is COM3 / USB
serial 28:84:85:92:B1:34; its MAC matches the earlier successful physical V2
acceptance evidence. Port identities are checked, not inferred from ordering.

Each hardware image embeds the same eleven fixtures, of which ten are tested;
slot zero is unused. The old build retains old playback/rendering code while
adapting panel and board initialization/presentation to the stable drivers. On
the small panel it also uses that panel's geometry. These are explicitly hybrid
builds, not unmodified historical firmware. SD cards remain unmounted.

Traces are buffered in RAM and printed after each scene. `report` validates file
hashes and every hardware frame/delay pair independently against SCN bytes.
Duration is measured from first-step decode to completion on ESP32, and session
start to completion on Windows. Loading is excluded; the small difference in
start boundaries should not be interpreted as a sub-frame timing regression.
Windows screenshots are disabled during timing. The native window must remain
visible, and normal desktop scheduling can affect its skipped-frame count.
Clock pixels can differ because Windows retains the current wall-clock date.

Output includes `report.md`, `summary.json`, `measurements.csv`, source patches,
flash logs, per-device raw serial traces, and isolated Windows API traces.
`restored.json` confirms successful restoration; `errors.json` records failures.
One repetition per scene is a pilot, not a statistical performance conclusion.

The larger 200-scene runner is tracked separately in
[PLAYBACK-TIMING-TODO.md](PLAYBACK-TIMING-TODO.md). This pilot does not implement
per-scene resume or USB scene staging and never starts a large run automatically.
