# DMDClock status

Last consolidated: 2026-10-17. This is the active project record. Historical
detail, completed checklists, prior release notes, and superseded plans are in
[`docs/legacy/`](docs/legacy/).

## v1.9.0 release

Windows and ESP32 appearance are accepted by the user. Windows now applies
verified whole-scene brightness mapping in normal playback; Last Action Hero
scene 010 maps `0,10,15` to runtime `0,8,15` on both platforms. Fresh screenshots,
settings, and provenance are linked from the README. Windows also uses the approved
100 ms regular-delay policy for stored 10 ms and missing/zero regular timings,
with full holds and no catch-up skipping. The state/capture API is verified locally
and can select indexed scenes. Both ESP32 targets include COM Wi-Fi provisioning.

See [v1.9.0 release notes](docs/development/RELEASE-NOTES-v1.9.0.md) and the
[current TODO](TODO.md) for the supported release scope and remaining checks.
The detailed candidate investigation records below preserve their original dates;
older pending labels and timings describe those candidates, not the current release.

## Done

- Windows application: SCN decoding, clock compositor, scene review, settings,
  local AppData storage, portable/standalone packages, screensaver support, and
  installer validation are established.
- Shared scene libraries: DMD-Large (2,416 scenes) and DotCLK-Orig (2,324
  scenes) have a tracked `scene-metadata.json` baseline and ESP32 card support.
- ESP32-S3: Waveshare 7 and 3.49B V2 / Rev1.1 targets build, support the DMD
  renderer, card scenes, web settings, touch, NTP, Wi-Fi, and release packaging.
  QEMU remains an automated integration gate rather than panel acceptance.
- Scene intensity metadata: all 2,416 DMD-Large file entries were enriched on
  2026-09-12 with verified hashes, frame counts, raw levels, and evenly-spaced
  mappings. Windows reader tests cover a verified and hash-stale record.
- ESP32 intensity runtime: schema-1 parsing, SCN hash/frame-count/value-mask
  verification, and 16-level lookup-table conversion are implemented.
- Windows intensity runtime (2026-10-17): normal playback and debug restarts now
  apply verified whole-scene mappings using the same conversion as Scene Reviewer.
  Scene bytes are reverified on load; invalid or stale metadata falls back to raw
  levels. All 220 core/API tests and 3 headless UI tests pass, including the actual
  Last Action Hero scene. Windows appearance was accepted by the user on 2026-10-17.
- ESP32 scene intensity mapping is visually accepted: scenes have substantially better
  colouring on the display.
- Windows installation, ESP32 PowerShell provisioning (including system-disk
  rejection), and physical ESP32 resilience are accepted. This includes card
  fault handling, power recovery, rendering, touch/web responsiveness, NTP,
  persistence, and soak behavior.
- The webpage already presents API-backed diagnostics through `/api/state`.
  Script-based scene preparation/copy provides the required local scene import.

## v1.9.0 Windows diagnostics iteration

Windows frame-pacing candidate (2026-10-17): every animation step now retains
its full hold after submission, with no catch-up skipping. That earlier candidate used a 10 ms missing-timing fallback; the approved
release policy now uses 100 ms as described above. Focused native validation saw
every step in nine runs, while sustained exact 10 ms cadence remains limited
by UI/rendering latency. See [behavior, evidence, and launch command](docs/development/WINDOWS-FRAME-PACING.md).
The subsequent full Standard50 run measured Windows 150 times against the 300
saved ESP32 captures: all 11,937 steps observed, zero skips, and 20 confirmed
duration differences against each board, all in the explicit 10 ms group.
Results: `output/timing/windows-vs-recorded-esp32-20261017/report.md`.
The repository retains the [full three-platform timing table](docs/development/PLAYBACK-PLATFORM-DIFFERENCES.md)
and [findings / remaining investigation TODO](docs/development/PLAYBACK-TIMING-TODO.md).

Implementation and automated validation are tracked in
[the dedicated v1.9.0 TODO](docs/development/V1.9.0-TODO.md).
Adds debug timing, frame stepping, temporary speed adjustment and an opt-in
LAN API with synchronized PNG/JSON captures. See
[API documentation](docs/development/WINDOWS-API.md) and
[candidate release notes](docs/development/RELEASE-NOTES-v1.9.0.md).
Native Windows visual/LAN/playback acceptance remains open. No timing fix or
public release is claimed.

## Want to do now

### Reproducible current playback comparison

- `scripts/Compare-CurrentPlayback.ps1` now provides interactive/CLI Prepare,
  Run, Resume, Report and Cleanup, Standard50, 5%/10%/50% and custom counts or
  percentages, deterministic nested selection, and exact manifest reuse.
- The checked-in `Standard50-v1` reference freezes 20 previously differing,
  20 diverse and 10 matching-control scenes. The earlier 200-scene dataset is
  retained. New run directories freeze scene hashes, source/binary identities,
  runtime settings and the independent 5% plus 50 ms thresholds.
- Both physical boards were application-flashed with `1.9.0-timing.2` on
  2026-10-17. Their Wi-Fi connections and natural NTP synchronization were
  present before deployment. Opt-in RAM capture, post-playback SD JSONL commit,
  COM retrieval and API status are implemented; capture defaults off at boot.
- Automated selection/evidence/report tests, PowerShell entry tests, production-C
  capture and serial tests, both firmware builds, and the Windows solution tests
  pass. The isolated visible native Windows capture smoke test also passes.
- Full live inventory verifies all 2,416 local/card SCNs match. Bulk timing
  replies use one buffered write on the requesting COM transport; an incomplete
  earlier inventory was rejected. Startup Wi-Fi joining is distinguished from
  a settings change. Both clocks remain connected and naturally NTP-synchronized.
- Standard50 completed: 450/450 main measurements and 90/90 qualification
  observations, with no missing/invalid captures and qualification passed.
  Local artifacts are under `output/timing/standard50-v1-20261017-final`.
- Windows has confirmed duration differences on 20/50 scenes against each ESP32
  and repeated skipped animation steps on 21/50. Both ESP32s cover all 11,937
  authored steps across their main repetitions; they differ in duration on
  three scenes (`RD1241`, `RD1239`, `RD1231`). These are software measurements,
  not GPU/display-drop or optical presentation measurements.
- Median ESP32 loop-to-decode spans are 1.135 ms / 1.462 ms (7-inch / 3.49B);
  decode-to-submission spans, including overlay/drawing, are 70.534 / 69.579 ms.
  No playback correction or publication is claimed.
- A physical Resume revalidated all inputs, kept all 540 raw evidence files
  byte-identical, and sent zero replay commands. Standalone Report and idempotent
  Cleanup pass. Both clocks finish with capture disabled, Wi-Fi connected and
  NTP synchronized; saved configuration readback and the Windows settings hash
  are unchanged. The earlier 200-scene comparisons hash is unchanged.
- HTML payload/raw links, CSV counts and JavaScript syntax pass automated checks.
  Browser visual preview was unavailable in the session. Windows normal glow is
  enabled; ESP32 uses 50% strength because
  Windows currently exposes glow only as on/off. Reports record that difference.
- Exact prerequisites, deployment and rerun commands are in the
  [standalone guide](docs/development/CURRENT-PLAYBACK-COMPARISON.md).

### ESP32 Wi-Fi provisioning over COM — local implementation

- Findings and staged work are recorded in the
  [serial Wi-Fi roadmap](docs/development/ESP32-SERIAL-WIFI-ROADMAP.md).
- Local candidate firmware supports serial identity/status and Wi-Fi credentials
  through UART and native USB readers. The PowerShell flasher and installer add
  optional `-ConfigureWifi` and `-WifiOnly` paths with hidden password entry.
- Both target builds and automated host tests pass. Follow the
  [operating guide](docs/ESP32-FLASH-AND-WIFI.md) for physical validation;
  publication and physical connection/persistence checks remain open.
- During live diagnosis, the 3.49B was application-flashed with
  `1.9.0-serial-wifi.3`. COM3 hello/status returned the expected firmware and MAC
  across three port reopen cycles; API counters independently showed USB input.
  No Wi-Fi credentials were sent and NTP remained unstarted. The 7-inch clock
  remains on its earlier firmware; its `.3` candidate builds successfully.
- Native USB follow-up: corrected the secondary-console input path after the
  first candidate produced a COM3 write timeout. Candidate
  `1.9.0-serial-wifi.1` requires both readers to initialize. A host test running
  the production C reader reproduces the original failure and passes after the
  fix; PowerShell now reports transport failures without retrying a broken handle.
- Further live diagnosis found the USB driver was required for RX availability.
  The final `.3` candidate uses buffered UART/USB drivers with explicit zero-timeout
  reads, and adds read-only serial counters to `/api/state`. Host tests and the
  3.49B live COM/API checks pass.
- The user completed 3.49B Wi-Fi-only setup through COM3. LAN API readback at
  `192.168.1.150` confirms `1.9.0-serial-wifi.3`, source NTP, and a successful
  recent automatic sync. Restart persistence and 7-inch physical setup remain open.
- The 7-inch clock was then application-flashed with `1.9.0-serial-wifi.3` on
  COM4. Its expected Waveshare7 identity/MAC passed hello/status across three
  port reopen cycles. The user subsequently completed Wi-Fi setup; live readback
  confirms `192.168.1.230` and natural NTP synchronization. Both boards retain
  their connections after the later timing-candidate application-flash restarts.

### P0 — browser authentication finish

- Browser authentication works, but same-browser session handoff is slow and
  not fully complete. Prioritize finishing and accepting this flow.

## Deferred roadmap

- Revisit package/hash release checks when a release is being prepared.
- macOS public-release work is deferred because Apple signing/notarization cost
  is the current stopper; the unsigned developer preview remains available.
- Consider weather and time features for Windows, macOS, and both supported
  ESP32 boards.

## Rules for closing work

- Build, unit, QEMU, serial, and HTTP evidence does not replace physical-panel
  or browser acceptance when that is the stated gate.
- Keep raw SCN files unchanged. Treat unverified intensity metadata as absent.
- Use `FullReset` or board-specific factory recovery to reset forgotten web
  credentials. Ordinary application or full flashing preserves NVS and does not
  reset them.
- Update this file after a meaningful implementation, validation, flash, or
  blocker; move an item to **Done** only with its relevant evidence.
