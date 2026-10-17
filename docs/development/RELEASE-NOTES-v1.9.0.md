# DMDClock v1.9.0

Windows now uses the same verified scene brightness-level mapping as ESP32.
ESP32 installation also gains Wi-Fi setup directly over the USB COM port.

## Windows

- Apply whole-scene `evenly-spaced-v1` mapping automatically when the scene's
  SHA-256, frame count, and used values match its metadata. For Last Action Hero
  scene 010, source levels `0,10,15` become runtime levels `0,8,15` on both platforms.
- Keep original scene files and clock pixels unchanged. Missing or invalid
  metadata falls back to the original levels. Scene Reviewer retains its
  raw/mapped comparison toggle.
- Present every animation step and hold it for its full duration after submission,
  including the final frame. Late callbacks no longer skip ahead to catch up.
- Use the approved 100 ms regular delay for stored 10 ms delays and missing/zero
  regular timing. Other explicit delays and opening/closing holds are preserved.
  Diagnostics show the original file timing and the effective playback target.
- Add an optional debug overlay, pause/frame stepping, 0.1x-4.0x debug speed,
  restart, JSON reports, and retained completion diagnostics.
- Add an opt-in bearer-token LAN API for state, playback controls, indexed scene
  selection, PNG screenshots, and synchronized state/image captures.

## ESP32 and installation

- Configure home Wi-Fi through UART/CH343 or native USB serial on supported
  Waveshare 7-inch and 3.49B V2 / Rev1.1 boards.
- Installer menu **7 - Configure Wi-Fi only** changes Wi-Fi without reflashing.
  Interactive flashing also offers optional COM Wi-Fi setup after success.
  Command-line equivalents are `-WifiOnly` and `-ConfigureWifi`.
- Verify protocol support and board/MAC identity before sending credentials;
  use hidden password entry and report association/IP success separately from
  saving credentials. Preserve other settings and existing NVS during normal updates.
- Fix native USB input handling and support full-length ESP-IDF SSIDs/PSKs.
- Add opt-in serial timing capture and reproducible comparison/report tooling;
  capture is disabled by default and does not require changing scene files.

## Screenshots and validation

See the [aligned brightness screenshots](../../README.md#aligned-scene-brightness)
and [current TODO](../../TODO.md). Windows screenshots come from its capture API;
ESP32 screenshots are framebuffer captures of the production renderer in QEMU,
not photographs. Both use matching scene metadata and 100% overall brightness.

The user has accepted the appearance of Windows and both physical ESP32 displays.
Automated validation covers Windows/core/API/rendering, serial provisioning,
firmware protocol/timing, and installer composition. Exact release artifacts have
their own build identities and checksums.

The Windows 100 ms policy is a visual preference, not a claim of original-machine
timing. Browser session handoff, cross-device Windows LAN acceptance, cold power-cycle
Wi-Fi checks, and deeper timing-reference work remain tracked in the TODO.
macOS public-release work remains deferred; this release supplies Windows and ESP32 assets.
