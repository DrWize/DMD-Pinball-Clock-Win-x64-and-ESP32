# Windows playback/debug API (v1.9.0)

Enable **LAN API settings…** in the display's right-click menu, choose a port
(default **17891**), and save. Copy the API token from that dialog. The status
shows the listening address or bind failure. Token regeneration takes effect on
Save. The API runs in normal application mode only, and stops with the app.

The server binds all network interfaces. Every request requires
`Authorization: Bearer <token>`. Tokens are stored in the existing per-user
settings and excluded from debug reports. HTTP is intended for a trusted LAN;
CORS is disabled, no firewall exceptions are added, and public exposure is not
part of this iteration. Existing installations default to API disabled.

## Endpoints

| Method | Path | Response |
| --- | --- | --- |
| GET | `/api/state` | Current state and retained last-scene diagnostics |
| POST | `/api/playback` | State after executing the command |
| GET | `/api/screenshot?includeDebug=false` | PNG plus `X-Capture-Id` header |
| GET | `/api/capture?includeDebug=false` | JSON with `state` and `screenshot` |

`includeDebug` accepts `true` or `false`; omitted means false. Capture excludes
window chrome, menus, startup and animation information overlays. It includes
the DMD display at current pixel size and optionally the debug timing overlay.
Image and state are captured in one UI-thread operation, without advancing the
player. Requests may wait for the UI thread. Captures above 16 million pixels
return 409. Responses are marked `Cache-Control: no-store`.

All errors have an HTTP status: 401 for invalid/missing authentication, 400 for
invalid commands/values, 409 for an unavailable playback action. Unknown routes
return 404. The maximum request body is 4096 bytes. Content type for commands
must be `application/json`.

### Playback commands

Send `{ "action": "load-scene", "scenePath": "LAST_ACTION_HERO_010.scn" }`
to load an indexed, valid scene from the current library. The path is relative to
that library; arbitrary filesystem paths are rejected. This uses normal verified
intensity mapping and preserves the current pause state and speed. Send `pause`
before loading to inspect the first frame, then `step-forward` to inspect the next.
The command cancels the pending animation cycle without changing saved settings.

Send `{ "action": "pause" }`, `resume`, `step-back`, `step-forward`, `restart`,
`debug-enable`, or `debug-disable`. Pause/resume are idempotent. Frame stepping
pauses playback and clamps at either end; it requires an active scene. Restart
resets the current scene, or reopens the retained completed scene, preserving
pause state and selected speed.

Send `{ "action": "set-speed", "speed": 0.5 }` to set speed. Enable debug first.
Valid speeds are 0.1–4.0 inclusive in 0.1 increments. Speed carries across scenes,
resets to 1.0 when debug is disabled or the app exits, and scales first/regular/
last delays together. Mid-frame changes preserve the remaining frame proportion.

### State and timing fields

`apiVersion` is 1. `appVersion` identifies the build. Each response snapshot has
`captureId` and UTC `capturedAt`, plus `displayMode`, `debugEnabled`, `paused`,
`speed`, `scene`, and `lastSceneResult`. A scene contains `file` (basename only)
and `timing`. Frame/step indices are zero-based; a blank hold has `frameIndex: -1`.
The overlay presents ordinary frame numbers starting at 1.

Timing includes:

- `frameIndex`, `totalFrames`, `stepIndex`, `totalSteps`, `isBlank`, `paused`, `completed`, `speed`.
- `timingSource` (`file`, `fallback`, or `override`), `timingLabel`, `timingNotSet`, `fallbackFps`.
- Current Windows policy also reports `timingAdjusted: true` and
  `timingSource: "override"` for stored 10 ms regular delays played at 100 ms.
  `fileFps` retains the stored value; target FPS and expected/adjusted durations
  describe effective playback. Explicit first/last holds are not overridden.
- `frameDelayMs` for the current step at 1× and `adjustedFrameDelayMs` at selected speed.
- `fileFps` for the regular file delay, and `adjustedTargetFps` after speed scaling.
- `measuredFrameUpdatesPerSecond`, `skippedFrames`, `sampleStartActiveMs`, `sampleEndActiveMs`.
- `expectedDurationMs` at 1×, `adjustedDurationMs` at current speed, `elapsedMs`, `actualDurationMs`, `status`.

Missing or zero regular timing uses **Timing not set**, **Fallback: 10 FPS**;
`fileFps` is null. A zero first/last hold means that hold is absent. Duration is
summed from actual playback steps, including nonzero holds and blanks.

Playback uses a monotonic clock. Elapsed time excludes pauses, and completed
actual time is retained. Rates measure application frame submissions, not GPU
presentation or monitor refresh. Current Windows pacing advances at most one
step per callback and retains the full hold after submission, so late callbacks
extend playback rather than skipping frames. Sampling uses active intervals of at least one second; unavailable
rates are null, including immediately after pause/resume, stepping and speed
changes. Long holds can validly report zero updates. Initial display submission
and manual steps are excluded from rate counts.

`status` marks **Manually stepped** or **Speed changed** for runs unsuitable for
an uninterrupted fixed-speed duration comparison. On such runs,
`adjustedDurationMs` describes the whole scene at the currently selected speed;
it is not a prediction of total runtime across previous speed changes. Use the
separate `paused` and `completed` flags regardless of status. Restart clears
these qualifications. Last-scene results remain until another scene starts.

### Combined capture JSON

```json
{
  "state": {
    "apiVersion": 1,
    "captureId": "7f4d459d-443f-4e9b-9585-ff8916ebf665",
    "capturedAt": "2026-10-15T19:30:00Z",
    "scene": { "file": "APOLLO_13_005.scn", "timing": { "frameIndex": 119 } }
  },
  "screenshot": {
    "mimeType": "image/png",
    "base64": "...",
    "width": 1012,
    "height": 244
  }
}
```

This abbreviated example omits other state/timing fields. Decode `base64` to PNG
bytes. FPS values refer to the recorded sampling interval; the frame index refers
to the captured image. `scene` is null when the clock/date is showing; retained
results in `lastSceneResult` then describe the previous scene, not the clock image.

## PowerShell example

```powershell
$clockAddress = 'http://CLOCK-PC:17891'
$clockHeaders = @{ Authorization = "Bearer $env:DMD_API_TOKEN" }
Invoke-RestMethod "$clockAddress/api/playback" -Headers $clockHeaders -Method Post `
    -ContentType 'application/json' -Body '{"action":"debug-enable"}'
Invoke-RestMethod "$clockAddress/api/playback" -Headers $clockHeaders -Method Post `
    -ContentType 'application/json' -Body '{"action":"set-speed","speed":0.5}'
$clockCapture = Invoke-RestMethod "$clockAddress/api/capture?includeDebug=true" -Headers $clockHeaders
[IO.File]::WriteAllBytes((Join-Path $PWD 'clock.png'), [Convert]::FromBase64String($clockCapture.screenshot.base64))
$clockCapture.state | ConvertTo-Json -Depth 10 | Set-Content 'clock-debug.json'
```

Keyboard: Space pauses/resumes; comma/Left and period/Right pause and step;
Down/Up change debug speed by 0.1×. Use the right-click debug menu to reset speed,
restart, toggle the overlay or copy the full state report.
