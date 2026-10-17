# Playback differences: Windows and both ESP32 platforms

Measured 2026-10-17. This is the maintained comparison snapshot for
**Standard50-v1**, using identical SCN hashes on all three platforms.
The full 50-scene table below is retained in the repository; detailed captures
remain in the local evidence directories.

## Platforms and evidence

| Platform | Measured implementation | Measurements |
|---|---|---:|
| Windows | Current frame-pacing candidate source, corresponding to local `1.9.0-frame-pacing.1`; isolated native diagnostic build | 150 fresh captures |
| ESP32 7 inch | Waveshare7, `1.9.0-timing.2` | 150 reused captures |
| ESP32 3.49 inch | Waveshare349B V2 / Rev1.1, `1.9.0-timing.2` | 150 reused captures |

Each scene runs three times per platform. The Windows captures were made after
the frame-pacing change; the ESP32 captures come from the earlier completed
Standard50 test. These are separate sessions, not synchronized new hardware
measurements. No ESP32 firmware change or playback rerun was needed.

All reported durations exclude scene loading. A confirmed duration difference
must exceed **both 5% and 50 ms**, in the same direction in at least two of the
three repetition pairs. Repetition indices pair historical and current sessions.
Coverage and timing are software observations, not GPU drops, monitor refresh,
or optical presentation.

## Findings

- **Every Windows step is now observed:** 11,937 / 11,937 across all 150
  captures, with zero skipped animation steps. Both ESP32 datasets also cover
  all 11,937 steps. The previous Windows dataset covered 6,260 and skipped 5,677.
- **20 / 50 scenes still differ in duration against each ESP32.** All 20 use
  explicit 10 ms regular timing. Every scene in this group remains shorter on
  Windows, even with complete step coverage.
- **The other 30 scenes have no confirmed Windows/ESP32 duration difference**
  under the agreed threshold. This does not mean their durations are identical.
- Windows now assigns each frame its full hold after submission and advances
  at most one step per callback. Late updates extend playback. A requested
  10 ms hold is not an exact sustained 100 FPS display guarantee.
- Missing/zero regular timing now uses the user-requested 10 ms Windows
  fallback; the earlier captures used 100 ms. The eight affected reference
  scenes retain their explicit 2–3 second holds, so the total expected change
  is 90 ms per scene in this sample. None exceeds the confirmation threshold.

For scenes with explicit regular timing, normalize each scene's median
duration by its file-defined duration, then take the median across that group:

| Scene group | Scenes | Windows | ESP32 7 inch | ESP32 3.49 inch | Confirmed differences vs each ESP32 |
|---|---:|---:|---:|---:|---:|
| 10 ms regular timing | 20 | 1.076x | 7.689x | 7.676x | 20 |
| Other explicit regular timing | 22 | 1.004x | 1.013x | 1.011x | 0 |

`1x` means the measured duration equals the file-defined duration. Missing
timing is excluded from this normalization because its fallback is a player
policy, not an authored regular delay. First/last holds are included in scene
duration. Standard50 deliberately includes known outliers; 20 / 50 is a
benchmark result, not an estimate of the whole library's failure rate.

For `LAST_ACTION_HERO_061.scn`, the file describes 137 steps at 10 ms, totaling
1.370 seconds. Median measured durations are old Windows **1.382 s**, current
Windows **1.475 s**, ESP32 7 inch **10.541 s**, and ESP32 3.49 inch **10.536 s**.
The current Windows and both ESP32 captures cover all 137 steps on every
repetition. The old Windows repetitions covered only 56, 59, and 67 steps.

The remaining speed difference is therefore in time spent per step, even when
step coverage is complete. The data does not yet isolate the underlying ESP32
processing/scheduling cause or establish an original player's intended motion.
Keep the next investigation focused on per-step timing and an external timing
reference before changing authored delays or slowing Windows to match hardware.

## All 50 scenes

Times are **seconds, median of three repetitions**, in frozen manifest order.
`Confirmed` means Windows differs against both ESP32s under the rule above;
`Below threshold` means no confirmed difference against either ESP32.
`Unset*` marks the changed Windows fallback, with explicit holds preserved.

| Scene | Regular delay (ms) | Windows (s) | ESP32 7 inch (s) | ESP32 3.49 inch (s) | Duration difference |
|---|---:|---:|---:|---:|---|
| `LAST_ACTION_HERO_061.scn` | 10 | 1.475 | 10.541 | 10.536 | Confirmed |
| `RD0005.scn` | 90 | 2.722 | 2.769 | 2.763 | Below threshold |
| `RD1241.scn` | 10 | 1.733 | 12.451 | 11.727 | Confirmed |
| `RD0940.scn` | 108 | 4.828 | 4.868 | 4.856 | Below threshold |
| `LAST_ACTION_HERO_031.scn` | 10 | 1.313 | 9.386 | 9.306 | Confirmed |
| `RD0011.scn` | 90 | 3.904 | 3.972 | 3.954 | Below threshold |
| `RD1816.scn` | 90 | 4.085 | 4.163 | 4.168 | Below threshold |
| `RD0216.scn` | 90 | 4.993 | 5.045 | 5.110 | Below threshold |
| `RD1305.scn` | 90 | 3.810 | 3.874 | 3.850 | Below threshold |
| `LAST_ACTION_HERO_016.scn` | 10 | 3.900 | 27.913 | 27.934 | Confirmed |
| `LAST_ACTION_HERO_045.scn` | 10 | 1.972 | 14.077 | 14.541 | Confirmed |
| `RD0048.scn` | 90 | 4.176 | 4.215 | 4.191 | Below threshold |
| `RD1750.scn` | 110 | 3.882 | 3.920 | 3.921 | Below threshold |
| `RD0856.scn` | 750 | 7.507 | 7.523 | 7.515 | Below threshold |
| `RD0971.scn` | 90 | 5.544 | 5.572 | 5.577 | Below threshold |
| `RD0407.scn` | 90 | 2.910 | 2.925 | 2.929 | Below threshold |
| `LAST_ACTION_HERO_041.scn` | 10 | 1.797 | 12.840 | 12.667 | Confirmed |
| `RD0859.scn` | 10 | 2.398 | 17.072 | 17.398 | Confirmed |
| `LAST_ACTION_HERO_043.scn` | 10 | 1.124 | 8.068 | 7.969 | Confirmed |
| `LAST_ACTION_HERO_036.scn` | 10 | 1.705 | 12.144 | 12.478 | Confirmed |
| `LAST_ACTION_HERO_024.scn` | 10 | 1.899 | 13.621 | 13.701 | Confirmed |
| `RD0532.scn` | 2000 | 6.002 | 6.010 | 6.002 | Below threshold |
| `RD0120.scn` | Unset* | 4.012 | 4.106 | 4.113 | Below threshold |
| `RD1154.scn` | Unset* | 3.012 | 3.107 | 3.106 | Below threshold |
| `RD1150.scn` | 110 | 9.319 | 9.409 | 9.378 | Below threshold |
| `ww03.scn` | 100 | 5.002 | 5.002 | 5.007 | Below threshold |
| `RD2124.scn` | 1000 | 8.007 | 8.017 | 8.032 | Below threshold |
| `RD1590.scn` | 90 | 14.354 | 14.548 | 14.588 | Below threshold |
| `RD0121.scn` | Unset* | 4.012 | 4.105 | 4.109 | Below threshold |
| `got10.scn` | 3000 | 3.001 | 3.001 | 3.004 | Below threshold |
| `RD1001.scn` | Unset* | 3.017 | 3.102 | 3.104 | Below threshold |
| `RD0490.scn` | 90 | 3.451 | 3.478 | 3.476 | Below threshold |
| `ij03.scn` | 110 | 8.097 | 8.178 | 8.160 | Below threshold |
| `APOLLO_13_009.scn` | 10 | 1.585 | 11.285 | 11.073 | Confirmed |
| `RD1806.scn` | Unset* | 3.015 | 3.105 | 3.107 | Below threshold |
| `LAST_ACTION_HERO_019.scn` | 10 | 0.808 | 5.761 | 5.817 | Confirmed |
| `LAST_ACTION_HERO_065.scn` | 10 | 1.623 | 11.549 | 11.344 | Confirmed |
| `RD0140.scn` | 90 | 1.727 | 1.757 | 1.774 | Below threshold |
| `RD1870.scn` | 90 | 0.817 | 0.833 | 0.832 | Below threshold |
| `RD1532.scn` | 90 | 5.001 | 5.020 | 5.020 | Below threshold |
| `APOLLO_13_008.scn` | 10 | 0.930 | 6.617 | 6.769 | Confirmed |
| `LAST_ACTION_HERO_035.scn` | 10 | 1.794 | 12.844 | 12.855 | Confirmed |
| `APOLLO_13_010.scn` | 10 | 2.862 | 20.447 | 19.933 | Confirmed |
| `RD0558.scn` | Unset* | 3.018 | 3.102 | 3.103 | Below threshold |
| `RD1239.scn` | 10 | 1.149 | 8.216 | 7.788 | Confirmed |
| `APOLLO_13_005.scn` | 10 | 2.383 | 16.992 | 16.976 | Confirmed |
| `RD1061.scn` | Unset* | 3.018 | 3.105 | 3.107 | Below threshold |
| `RD2121.scn` | Unset* | 3.015 | 3.103 | 3.105 | Below threshold |
| `LAST_ACTION_HERO_037.scn` | 10 | 2.056 | 14.690 | 14.652 | Confirmed |
| `RD1231.scn` | 10 | 1.762 | 12.608 | 11.717 | Confirmed |

## Evidence and identities

- [Frozen scene reference](../../tests/fixtures/playback/Standard50-v1.json):
  SHA-256 `516550b4c469e589c37653f5c810004243da75996e08aed8bcd855edbe0f2e94`.
- [Current comparison report](../../output/timing/windows-vs-recorded-esp32-20261017/report.md),
  [per-scene CSV including min/max and skipped-step counts](../../output/timing/windows-vs-recorded-esp32-20261017/scene-comparison.csv),
  and [summary](../../output/timing/windows-vs-recorded-esp32-20261017/summary.json).
- [Current build/source provenance](../../output/timing/windows-vs-recorded-esp32-20261017/provenance.json):
  source-hash manifest SHA-256 `d4b94c04aff4cf577c1095f28f0da9f5b9351d972ff55b5db3f354b69556cd7d`.
  Diagnostic copies have isolation/instrumentation changes; the source hashes
  distinguish them from the packaged candidate and earlier Windows build.
- [Earlier Standard50 report](../../output/timing/standard50-v1-20261017-final/report.md)
  and [frozen platform builds](../../output/timing/standard50-v1-20261017-final/frozen-builds.json).
- ESP32 ELF SHA-256: 7 inch
  `5722a6035c7e7d62f61347aba6c43fafb3473af75278b36cdda671722107ed7b`;
  3.49 inch
  `5323972306ac7c55dcf31cea927cec2274daa304d9b907ce7683d578c3178155`.

All 450 earlier raw captures and the reference manifest were verified unchanged
after comparison. The earlier 200-scene comparison SHA-256 remains
`60da03ef600ce18739b42e7b78f7f837640ac35738af882602a36e2355ded684`.
Evidence under `output/` is local and Git-ignored; keep those directories when
sharing raw measurements. This document retains the findings and full median
table independently of those directories.

The reference manifest retains its original expected timings. The current run
records the eight version-specific fallback expectations separately in
`candidate-timing-expectations.json`; it does not regenerate Standard50-v1.
The general PowerShell comparison runner still needs support for this
version-specific expectation policy before its strict duration validation can
accept these changed fallback scenes. See the remaining work in
[the playback TODO](PLAYBACK-TIMING-TODO.md).

Related: [Windows candidate behavior](WINDOWS-FRAME-PACING.md),
[comparison operating guide](CURRENT-PLAYBACK-COMPARISON.md), and
[playback TODO](PLAYBACK-TIMING-TODO.md).
