# DMDClock TODO

Updated 2026-10-17 for v1.9.0. This is the current work list; detailed evidence
and historical investigations remain in [STATUS.md](STATUS.md) and
[the developer guide](docs/development/README.md).

## Completed for v1.9.0

- [x] Apply verified, evenly spaced scene brightness levels during normal
  Windows playback, matching the ESP32 runtime level mapping.
- [x] Keep source SCNs, masks, clock pixels, and explicit opening/closing holds
  intact; fall back to raw levels when intensity metadata does not verify.
- [x] Present every Windows playback step with its full hold after submission.
  Use 100 ms for stored 10 ms regular delays and missing/zero regular timing;
  retain other explicit delays. This is the approved visual playback policy.
- [x] Add Windows timing diagnostics, pause/step/speed controls, retained results,
  and authenticated state, scene selection, and PNG/JSON capture APIs.
- [x] Add ESP32 Wi-Fi setup over UART/native USB COM ports, including installer
  menu option 7, optional setup after flashing, and Wi-Fi-only setup.
- [x] Validate serial identity, connection/IP reporting, hidden password entry,
  settings preservation, and failure handling with automated tests.
- [x] Accept Windows and both ESP32 displays visually with the user.
- [x] Capture the aligned Last Action Hero brightness examples linked from the
  [README](README.md#aligned-scene-brightness).

## Next priorities

- [ ] Finish the ESP32 same-browser authentication/session handoff; retain the
  existing authentication and factory-recovery behavior.
- [ ] Verify the final downloaded release installer and both board packages
  from a clean folder, including COM Wi-Fi setup on both USB transports.
- [ ] Test Windows API access from another LAN device and token rotation after
  restart. Local authenticated API/capture operation is already verified.
- [ ] Add a targeted cold power-cycle Wi-Fi persistence check on each board;
  successful application-flash restarts are already recorded separately.
- [ ] Obtain matched, timestamped pinball-machine references before claiming
  machine-authentic animation timings. Keep the frozen comparison evidence.
- [ ] Investigate the remaining ESP32 render/submission overhead and the three
  recorded board-to-board timing differences without changing source scenes.
- [ ] Consider weather/time features across Windows and both ESP32 boards.
- [ ] Revisit a public macOS release when signing/notarization is available;
  the older unsigned preview remains separate.
