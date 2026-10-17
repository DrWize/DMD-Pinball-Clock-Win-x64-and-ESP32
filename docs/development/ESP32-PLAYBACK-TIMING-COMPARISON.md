# ESP32 reference and native Windows playback timing

Investigation: 16 October 2026. Hardware: user-confirmed Waveshare
ESP32-S3-Touch-LCD-7 (800×480), connected through COM4.

## Finding

**The reported Windows-versus-ESP32 speed difference is reproduced.** The user
clarified that Windows looked faster than the ESP32 and confirmed that the
earliest ESP32's animation pace matched the desired reference.

The native Windows app finishes the fast Apollo scene in about **1.488 seconds**,
versus **8.795 seconds** on the earliest ESP32 in Basic orange: roughly **5.91×
the playback speed**. Windows at 1× follows the SCN timeline and skips overdue
frames; ESP32 renders each step and allows the scene to take longer when the
display task cannot keep up. These different scheduling policies already exist
in the earliest implementations, rather than being a newly introduced speed
multiplier in the Windows candidate.

ESP32-to-ESP32 results are mixed: some Plasma scenes really are faster on
v1.8.0 than on the earliest ESP32 code; other scenes are unchanged or slower.
The SCN delays themselves were not shortened.

The board was actually flashed and measured for both versions. This is separate
from the earlier [Windows core comparison](PLAYBACK-VERSION-COMPARISON.md).
No Teensy code or hardware was used for these ESP32 measurements.

## Native Windows versus the accepted ESP32 pace

The actual current Windows app was built and run in native Avalonia windows,
not headless mode. Each scene/mode was repeated twice at default 1×, using its
existing authenticated debug API to record completed durations and skipped
frames. Native-rendered PNG captures were saved; an Apollo capture was visually
inspected and showed the dot-matrix scene.

| Scene | Mode | Earliest ESP32 | Native Windows 1× | Windows speed relative to ESP32 |
| --- | --- | ---: | ---: | ---: |
| afm01.scn | Basic orange | 6.913 s | 6.910 s | 1.00× |
| afm01.scn | Plasma | 7.381 s | 6.910 s | 1.07× |
| APOLLO_13_009.scn | Basic orange | 8.795 s | 1.488 s | 5.91× |
| APOLLO_13_009.scn | Plasma | 7.712 s | 1.476 s | 5.23× |
| RD1116.scn | Basic orange | 1.585 s | 1.548 s | 1.02× |
| RD1116.scn | Plasma | 2.112 s | 1.557 s | 1.36× |
| RD1474.scn | Basic orange | 3.742 s | 3.715 s | 1.01× |
| RD1474.scn | Plasma | 4.172 s | 3.721 s | 1.12× |

All 16 native cases completed cleanly at 1× with expected durations matching
the SHA-256-identical hardware fixtures. Windows skipped 69/77 overdue frames
in the two Basic Apollo runs, and 74/75 in Plasma. The ESP32 processed all 147
steps in each corresponding Apollo run. Other tested Windows scenes reported
zero skipped frames.

Unlike ESP32, Windows advances deadlines by each step's duration and uses a
`while` loop to catch up when a timer callback arrives late. Rendering capacity
can therefore change which intermediate frames appear without proportionally
lengthening the scene. This explains the large cross-platform difference and
why the earlier unchanged-Windows-code result did not resolve the user's concern.

Only the copied Windows app's data paths and API loopback binding were changed
for isolation. Playback, rendering, timer cadence, and debug timing logic were
retained. Installed Windows settings were untouched; all test app processes
were closed after measurement. A single global speed factor cannot match the
old ESP32 across all tested scenes/modes, whose observed ratios range from
about 1.00× to 5.91×. Matching the accepted ESP32 pace would need a separately
specified playback policy; this investigation does not apply a Windows fix.

## Measured durations

Each result is the mean of two on-board repetitions. Negative duration change
means the newer version finished sooner. File timing includes all first/last
holds, and is not a measurement of the device's achieved rate.

| Scene | Mode | File timing | Earliest ESP32 | v1.8.0 | Duration change |
| --- | --- | ---: | ---: | ---: | ---: |
| afm01.scn | Basic orange | 6.900 s | 6.913 s | 6.926 s | +0.2% |
| afm01.scn | Plasma | 6.900 s | 7.381 s | 7.031 s | −4.7% |
| APOLLO_13_009.scn | Basic orange | 1.470 s | 8.795 s | 11.291 s | +28.4% |
| APOLLO_13_009.scn | Plasma | 1.470 s | 7.712 s | 10.168 s | +31.8% |
| RD1116.scn | Basic orange | 1.540 s | 1.585 s | 1.575 s | −0.6% |
| RD1116.scn | Plasma | 1.540 s | 2.112 s | 1.931 s | −8.6% |
| RD1474.scn | Basic orange | 3.710 s | 3.742 s | 3.741 s | approximately 0% |
| RD1474.scn | Plasma | 3.710 s | 4.172 s | 4.212 s | +0.9% |

For RD1116 in Plasma, earliest-code repetitions were 2.110 and 2.114 seconds;
v1.8.0 repetitions were 1.970 and 1.893 seconds. Both newer measurements were
shorter, although the variation shows that two samples do not establish a
precise universal multiplier.

For the fast Apollo scene, all 147 steps were processed by both versions. The
earliest firmware delivered about 16.7 frames/s in Basic orange instead of the
file's requested 100 frames/s; the newer firmware delivered about 13.0 frames/s.
The long duration is a real hardware/rendering limit, not a changed SCN header.

## Why the result depends on the scene and mode

The earliest ESP32 source (`90cee54`, 28 July 2026) already uses:

```c
if (playing_scene && monotonic_now >= next_scene_frame_at) {
    // Decode one step, then:
    next_scene_frame_at = monotonic_now + step_info.duration_ms * 1000;
}
vTaskDelay(pdMS_TO_TICKS(5));
```

The same scheduling rules remain in v1.8.0 and the current working firmware:
one step per eligible display-loop iteration, delay measured from the current
iteration, and no loop that skips overdue steps to catch up. A zero regular
delay still falls back to 100 ms. These source predicates were checked at the
initial ESP32 commit, all 15 ESP32-bearing version tags, and HEAD.

Rendering and refreshing the LCD happen in the same task. Plasma forces
additional renders between scene steps. A deadline is not processed until
that task returns to the scheduling check. Changing the cost of a render pass
can change how many passes elapse before the next scene step is due. Overshoot
then accumulates because the next deadline starts from the current iteration.

Examples from actual traces:

- RD1116 asks for 110 ms regular frames. Earliest Plasma intervals were about
  150–153 ms. Newer Plasma intervals were about 128–154 ms.
- AFM asks for 100 ms regular frames. Earliest Plasma regular intervals were
  about 143–149 ms; newer regular intervals were about 102–104 ms.
- Apollo asks for 10 ms frames, faster than either version can render. Its
  actual speed follows the cost of each render/refresh cycle.

This explains why an unchanged delay value does not prove unchanged hardware
playback speed. It also explains why a global slowdown would not reproduce the
earliest behavior for every scene and effect.

On 30 July, `3ac60ba` introduced double framebuffers and a wait for the RGB
framebuffer handoff. This changes the display-loop workload. The old/new matrix
does not attribute every performance difference to that one commit. The
pre-change v1.2.0 source was also flashed for six targeted RD1116/Plasma samples
(about 2.14 seconds each). The post-change intermediate was built but not flashed
after the user clarified that Windows-versus-ESP32 was the relevant comparison.

## Controlled test setup and verification

- Earliest source: `90cee549660c5783b534ea343aff4aeaef4b3566`.
- Latest source: tag v1.8.0 (`4145cb2`). There is no firmware-source diff between
  that tag and the current checkout, including its uncommitted Windows work.
- Same physical chip and panel, ESP-IDF 5.5.2, compiler configuration,
  240 MHz CPU, 80 MHz octal PSRAM, 64-byte data-cache lines, and 1 kHz RTOS ticks.
- Both builds use the existing debug optimization setting, matching the
  workstation's normal v1.8.0 hardware build.
- Same input scene bytes, verified against SHA-256 manifests in both snapshots.
- Brightness 100%, glow 50%, built-in 5×7 clock, 24-hour time, seconds hidden,
  information overlay hidden, and an 8-second Neon Plasma cycle. Hot-core,
  schedules, automatic playback, MQTT, and playback logging are disabled where
  supported. Network station credentials are empty for these isolated tests.
- The clock is initialized to the same test date. No station/NTP traffic is
  needed. The normal renderer and deadline calculations are retained.
- Test fixtures are embedded in flash. The SD card is left unmounted, preserving
  its contents and avoiding differences in scene loading or metadata.
- A common small probe stores step/frame/delay and monotonic timestamps in RAM.
  It records decode completion, first render/present completion, and scene end.
  It prints the trace only after the scene finishes, avoiding per-frame serial
  logging during playback.
- The embedded fixtures require a 4 MB test application partition. NVS, PHY,
  and application start offsets stay at 0x9000, 0xf000, and 0x10000. Both images
  pass the ESP-IDF partition-size check and esptool's written-data verification.

**All 32 hardware cases and all 1,480 ordered playback steps passed validation.**
The analyzer independently reconstructs frame indices and delays from SCN
bytes, checks each recorded sequence, and verifies paint timestamps. The old
firmware truncates Apollo's name in its small active-name buffer; the analyzer
resolves it through the requested fixture index and original SHA-256 manifest.

These are instrumented real-panel runs, not unmodified release binaries or
optical measurements. Timings include the original render/refresh functions;
an original single-buffer write is not equivalent to a newer synchronized
framebuffer presentation. Two samples per scene/mode support this comparison,
not every scene, SD configuration, font, or effect setting.

## Evidence and reproduction

The complete original 16 MB flash image was backed up before any firmware write.
Its size and SHA-256 are recorded alongside it under the ignored directory:

`output/esp32/timing-comparison/original-com4-3c0f02c359d8/`

Old/new measurement evidence:

`output/esp32/timing-comparison/20261016T193944Z/`

This contains scene hashes, source revisions, instrumentation diffs, generated
SDK configuration, successful build logs, image hashes, verified flash logs,
raw serial traces, validated measurements, `hardware-summary.json`, and
`hardware-results.md`. `cross-platform-summary.json` and
`cross-platform-results.md` combine the native Windows and hardware measurements.
Original backup files may contain device configuration;
they remain local build artifacts.

Native Windows evidence is under
`output/esp32/timing-comparison/windows-native/`: source hashes,
`isolation.patch`, build log, native measurements, per-case API state traces,
and PNG captures. The copied app stores settings/logs/selections exclusively
inside that directory and binds its test API only to loopback.

Preparation and analysis are separate from flashing:

```powershell
python scripts/esp32/tests/Prepare-PlaybackTimingComparison.py
# Build each printed project with the pinned ESP-IDF environment, an isolated
# SDKCONFIG under build-timing, and an explicit PROJECT_VER.
# Use the ESP-IDF Python environment (with pyserial) for the capture command:
python scripts/esp32/tests/Run-PlaybackTimingCapture.py <evidence-directory> oldest --backup-meta <verified-backup.json>
python scripts/esp32/tests/Run-PlaybackTimingCapture.py <evidence-directory> latest --backup-meta <verified-backup.json>
python scripts/esp32/tests/Analyze-PlaybackTimingCapture.py <evidence-directory>
python scripts/Compare-NativeWindowsPlayback.py <native-evidence-directory>
python scripts/esp32/tests/Analyze-PlaybackTimingCapture.py <evidence-directory> --windows <native-evidence-directory>
```

The capture tool verifies the connected USB identity against the backup metadata,
checks the original 16 MB backup hash, and rejects QEMU or incompatible panel
configuration. The production source files and installed Windows settings are
unchanged by this investigation. No playback fix has been applied.

## Connected display and visual acceptance

The user accepted the oldest firmware's **pace**, but subsequently reported
flicker when its single-framebuffer display driver ran continuously. The board
remained responsive and showed frame progression over UART. The old driver
writes into a buffer concurrently scanned by the LCD, a plausible source of
tearing/flicker. After restoring the v1.8.0 double-buffered driver, the user
confirmed: **the display is stable**. This is physical acceptance from the user,
not an inference from build or UART results.

The old pace remains a captured reference; its flickering display driver is
not the desired final runtime. **The connected board is left on
`1.8.0-reference`, built from v1.8.0 with the modern panel driver and continuous
playback.** It embeds the same fixtures, leaves the SD card unmounted, and
provides UART-only test controls for selecting a scene, setting the current
time, querying state, and restoring automatic playback. It is a diagnostic
image, not a new public release or a claim that the older pace has been applied
to the newer renderer.

The final image passed the build/partition-size checks and written-image hash
verification. UART reported source `4145cb2`; the host set the current epoch
and automatic playback. Initial frame progression was recorded, then the
monitor was closed. A later read-only UART session observed scene 5 advancing,
the clock interval, and automatic transition to scene 6 with frame advancement.
This verifies playback keeps cycling after the measurement process exits.

Final runtime evidence:
`output/esp32/timing-comparison/20261016T200600Z/`, including
`stable-reference-flash.json`, `stable-reference-flash.log`,
`stable-reference-serial.log`, `reference-state.json`, and
`continuous-after-monitor-closed.json`. The v1.8.0 panel driver is the same
driver the user confirmed stable after the old single-buffer flicker.
