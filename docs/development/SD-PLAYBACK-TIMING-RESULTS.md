# 200-scene ESP32 and Windows timing results

Completed 17 October 2026. Both boards were restored to their verified pre-test
flash snapshots. No production playback fix or SCN change was applied.

## Finding

**Windows finishes many of the selected scenes sooner than either ESP32. No
old-to-new ESP32 firmware timing change was confirmed under the repeat criteria.**
This is a cross-platform scheduling difference, rather than evidence that a
recent Windows release accelerated the scene timeline.

All 2,416 SCN files match by filename, length, and SHA-256 across Windows and
both SD cards. No content synchronization is needed.

The 200-scene sample produced 1,000 initial measurements. All 94 scenes flagged
by the initial pair comparisons were played twice more on all five targets,
adding 940 measurements. The final dataset contains **1,940 validated scene
measurements**, plus 50 SD-path qualification measurements. No required cases
or repeats are missing. Each target has 388 sample measurements.

The full-library run was not triggered: the user authorized expansion only if
the sample showed no confirmed difference, and this sample did show differences.

## Duration versus frame skipping

First-pass playback totals for the same 200 scenes, excluding loading, SD log
writes, USB collection, flashing, and restoration:

| Target | Playback time | Skipped steps |
| --- | ---: | ---: |
| Windows local v1.9.0, 1x | 17.37 minutes | 1,868 |
| 7-inch ESP32, earliest playback hybrid | 24.37 minutes | 0 |
| 7-inch ESP32, v1.8.0 playback | 24.40 minutes | 0 |
| 3.49B V2 ESP32, earliest playback hybrid | 23.98 minutes | 0 |
| 3.49B V2 ESP32, v1.8.0 playback | 24.39 minutes | 0 |

The files request 17.33 minutes in total. Windows finished every first-pass
scene within 31 ms of its requested duration, while skipping overdue steps in
32 scenes. Repeated skipping was confirmed in 29 scenes. ESP32 processed the
complete expected frame/delay sequence in every measurement.

Confirmation requires three measurements on both targets and either a duration
difference exceeding both 5% and 50 ms in the same direction in at least two
paired measurements, or repeated skipped steps. Counts below can overlap.

| Comparison | Confirmed duration differences | Repeated skipped-frame cases |
| --- | ---: | ---: |
| 7-inch earliest vs Windows | 94/200 | 29/200 |
| 7-inch v1.8.0 vs Windows | 94/200 | 29/200 |
| 3.49-inch earliest vs Windows | 92/200 | 29/200 |
| 3.49-inch v1.8.0 vs Windows | 92/200 | 29/200 |
| 7-inch earliest vs v1.8.0 | 0/200 | 0/200 |
| 3.49-inch earliest vs v1.8.0 | 0/200 | 0/200 |

The median per-scene old-to-new duration change was +0.05% on the 7-inch and
+1.46% on the smaller board. These are small measured changes; the result does
not establish exact performance equality. Comparing boards at the same version
also found 25 confirmed duration differences on the old hybrids and four on
v1.8.0, so neither board is a universal timing substitute for the other.

Examples below use each scene's median measured duration; repeated scenes have
three observations per target, and unflagged scenes have one.

| Scene | Windows | 7 old | 7 new | 3.49 old | 3.49 new |
| --- | ---: | ---: | ---: | ---: | ---: |
| APOLLO_13_009.scn | 1.475 s | 11.295 s | 11.294 s | 10.954 s | 11.327 s |
| RD1241.scn | 1.622 s | 12.447 s | 12.449 s | 11.552 s | 11.978 s |
| afm01.scn | 6.916 s | 6.924 s | 6.928 s | 6.921 s | 6.947 s |

## Explanation and suggested alignment

Windows advances through all overdue steps in one callback, retaining the SCN
timeline. ESP32 advances one step per loop and schedules the next deadline from
that loop's current time. Loop and rendering costs can therefore stretch short
delays on ESP32. The effect varies substantially by scene.

The Windows behavior is present in the initial commit `186a572`, rather than
being introduced by v1.8.0 or the local v1.9.0 diagnostics. See the separate
[version investigation](PLAYBACK-VERSION-COMPARISON.md).

Recommended next implementation, for separate review:

1. Keep the current file-timeline 1x mode available.
2. Add an optional Windows mode that preserves every intermediate step. This
   would remove catch-up skipping, but faster Windows rendering means it would
   not by itself reproduce ESP32 duration.
3. If the desired result is specifically the ESP32 pace, choose one reference
   board/version and test a separate compatibility mode against its measured
   per-step intervals. The stable 7-inch v1.8.0 observations are exported in
   `esp32-pacing-reference.json` for review. They cover the selected sample,
   and do not yet define a general solution for untested scenes.

A single global speed multiplier cannot reproduce both the near-identical AFM
timing and the much slower ESP32 Apollo timing. Making ESP32 meet file deadlines
would instead require changing its scheduling/rendering behavior, potentially
skipping frames; that is a separate product choice. No such change was made.

## Coverage and limits

The reproducible sample contains 50 largest scenes, 50 fastest remaining scenes,
50 timing controls, and 50 representative-game scenes, including the ten pilot
controls. It includes 19 zero regular delays, 50 first holds, 79 last holds,
16 blank first holds, and five blank last holds. It is a stress/coverage sample,
not a random estimate of how often differences occur across the full library.

Earliest ESP32 playback is `90cee549660c5783b534ea343aff4aeaef4b3566` with stable
board, panel, SD, and diagnostic adapters. These are explicitly hybrids, not
unmodified historical firmware benchmarks. Newer playback is v1.8.0
`4145cb297b77d47e1db4588e2f286a3f78409892`; Windows is the frozen local v1.9.0
working source. All targets used Basic orange at 1x with a controlled clock
input. The installed Windows settings were isolated from the test app.

The timestamps measure software decoding/render submission and completion,
rather than optical panel presentation. Only flagged scenes have three sample
measurements; no detected difference on an unflagged scene is not proof of
identical timing. No Teensy was used.

## Evidence and validation

Run directory: `output/esp32/sd-timing-20261016/`.

- [Interactive scene comparison](../../output/esp32/sd-timing-20261016/report.html)
- [Complete report](../../output/esp32/sd-timing-20261016/report.md)
- [Measurements CSV](../../output/esp32/sd-timing-20261016/measurements.csv)
- [Per-step timings CSV](../../output/esp32/sd-timing-20261016/step-timings.csv)
- [Completion audit](../../output/esp32/sd-timing-20261016/completion-audit.json)

The completion audit passed frozen source/image/configuration checks, full input
alignment, reproducible selection, raw qualification evidence, complete initial
and repeat coverage, the conditional expansion decision, firmware restoration,
and physical SD checkpoint recovery. Four old/new logs were recovered unchanged
after firmware changes, and both cached RUN checks returned without replaying
the scene. Both 16 MB restores passed esptool hash verification with matching
chip identities. No test-owned app, runner, or serial process remains active.

All seven runner evidence tests pass. The standalone report's JavaScript passes
`node --check`. Physical visual acceptance of any future playback change remains
separate from these software measurements.
