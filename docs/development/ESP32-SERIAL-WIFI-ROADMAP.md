# ESP32 Wi-Fi setup over COM: roadmap

Status: local implementation, 2026-10-17. Firmware serial provisioning and
PowerShell integration are implemented. Both board builds and automated host
tests pass. The 3.49B now runs `1.9.0-serial-wifi.3`; physical COM3 hello/status
checks passed across three port reopen cycles and were confirmed by API counters.
Wi-Fi credential/persistence checks, 7-inch COM validation, and publication remain
open. No home Wi-Fi credentials or NTP sync were sent during diagnosis. See the
[operating guide](../ESP32-FLASH-AND-WIFI.md).

Follow-up: the original local candidate used the primary USB VFS path for the
secondary console and left native USB input unread. Corrected in local candidate
`1.9.0-serial-wifi.1`; the production C reader now has a host regression test.
That first correction was insufficient in the live test. `.3` uses buffered
UART/USB driver reads with explicit zero timeouts and has passed the 3.49B checks
above. `/api/state` exposes reader/poll/RX/request counters for future diagnosis.

## Goal

Provide a repeatable Windows procedure to flash either supported clock, enter
home Wi-Fi credentials over its USB COM connection, and verify connectivity.
The user should be able to run it from PowerShell without ChatGPT, a custom
firmware build, or switching the PC to the clock's access point.

## Findings from the current implementation

- Published ESP32 packages for both boards are v1.8.0. The local v1.9.0 candidate
  adds Windows diagnostics; it does not add ESP32 serial provisioning.
- Production ESP32 firmware has no command reader for Wi-Fi credentials.
  `main/dmd_network.c` already provides `dmd_network_apply_credentials()`;
  settings persistence is available through `dmd_settings_update()`.
- The web settings path saves credentials and then applies them. Serial setup
  can reuse this behavior instead of maintaining a second settings store.
- The bootstrap build helper embeds credentials in a local firmware image.
  It is useful for development but requires a rebuild and leaves credentials
  inside that image. It should remain an alternative, not the normal workflow.
- The timing-test preparation script clears the SSID/password and persists
  them. Restoring an application image preserves those saved empty settings.
  This is consistent with today's saved API records showing no station IP and
  NTP never started. A fresh device read is still needed before recovery.
- Application and Full flashing preserve NVS. FullReset is unnecessary for
  ordinary Wi-Fi recovery and would reset unrelated settings.
- Recorded USB identities map Waveshare7 to CH343 serial `5B3E087595` (COM4)
  and Waveshare349B to native USB serial `28:84:85:92:B1:34` (COM3).
  Recheck identities on every run; COM numbers are not permanent identifiers.
- The checked-in SDK configuration uses UART0 as the primary console and native
  USB Serial/JTAG as a secondary console. Seeing logs on native USB does not
  establish a working input path. Verify both transports before choosing the
  final reader implementation.

Source pointers: `scripts/esp32/tests/Prepare-PlaybackTimingComparison.py`,
`firmware/dmdclock-esp32/main/{dmd_network.c,dmd_settings.c,dmd_web.c}`,
`scripts/esp32/dev/Set-DmdClockBootstrapWifi.ps1`, and the local timing run's
`run.json`. Paths above are relative to the repository root except `main/`.

## Recommended approach

Implemented protocol v1 uses `DMDWIFI:` followed by one JSON object and newline,
at 115200 baud. Requests contain `protocol`, a string `id`, and `op` (`hello`,
`status`, or `setWifi`). `setWifi` additionally requires the MAC returned by
`hello`, `ssid`, and an explicit `password`. Lines must fit in 1024 bytes including
the newline. Replies echo the ID and include `ok`; status includes board, MAC,
firmware, association SSID, IP, and NTP state. The host paces 32-byte chunks to
avoid overrunning unbuffered input. No replies echo credential requests.

Add a small, versioned serial provisioning interface to normal ESP32 firmware,
then expose it through the existing PowerShell installer. Provision after
flashing; reuse the saved credentials on future updates unless the user chooses
to change them. Keep the existing AP/web setup as recovery.

Do not write a generated NVS partition directly as the normal provisioning
method: it couples the installer to storage details and makes preserving
unrelated settings harder. Do not compile user credentials into release images.

### 1. Establish transport and identity

- Verify receive and transmit on UART/CH343 and native USB Serial/JTAG, including
  USB re-enumeration after flashing. Inspect the actual build configurations
  for both targets, not only the checked-in default.
- Choose a reader for each transport that coexists with logging and display
  tasks. Do not assume a common `stdin` reader receives both paths.
- Define a read-only identity/capability exchange containing protocol version,
  board target, firmware version, and MAC/device identity.
- Keep DTR/RTS from resetting a running device during provisioning; let the
  flashing step own its deliberate reset. Require a positive identity match
  after reopening a port.

### 2. Add firmware provisioning

- Proposed operations: identity/capabilities, redacted Wi-Fi status, and set
  SSID/password. Do not add arbitrary settings, shell execution, or clock-setting
  commands to this feature.
- Use bounded newline-delimited JSON requests and distinctly prefixed JSON
  replies, with request IDs so the host can distinguish replies from boot logs.
  Finalize field names and limits after the transport spike.
- Validate UTF-8 byte lengths using the existing settings limits. Require an
  explicit password field; an empty value means an open network. Never echo
  the supplied password or raw credential request.
- Serialize credential changes with web configuration updates, preserve other
  settings, save through the shared settings layer, and apply network changes.
- Distinguish saved credentials, connection in progress, obtained IP, and
  failures. Report persistence failures separately, including a failed SD
  settings mirror; do not report complete success from an acknowledgment alone.
- Keep AP recovery available after a wrong password or unavailable network.
  Connection failure must permit retry without a factory reset.

### 3. Integrate PowerShell and write the operating guide

- Add a standalone Wi-Fi setup entry point that also works without reflashing;
  share its implementation with the existing flash/install workflow.
- Prompt for SSID and a hidden password. Keep passwords out of command lines,
  shell history, transcripts, provisioning logs, and saved result files.
- Reopen the identified device after flash, detect protocol support, provision,
  and wait for an IP with a bounded timeout and actionable failure messages.
- Older firmware must produce an explicit unsupported-feature result with AP/web
  instructions, rather than receiving credentials blindly.
- Extend `-WhatIf` to describe provisioning without opening ports or asking for
  a password. Keep ordinary updates from changing credentials implicitly.
- Write a user guide with prerequisites, board identification, exact commands
  for both targets, download/update versus offline reuse, application flashing,
  Wi-Fi-only setup, verification, and recovery from port or connection failures.
- Keep firmware packages free of user credentials. Record the selected release,
  artifact hashes, device identity, IP, and redacted validation results.

### 4. Validate, then use the guide on both clocks

- Test malformed/oversized input, Unicode and escaped credentials, missing
  fields, wrong password, unavailable AP, interleaved logs, timeouts, and
  unsupported protocol versions. Confirm no credential leakage on failure.
- Test settings preservation, simultaneous web/serial changes, and save errors.
  Exercise serial port disappearance/reappearance and refusal of a wrong device.
- Build both board targets and test the host workflow with simulated replies.
  Then prove input, provisioning, restart persistence, and normal display/touch
  behavior on both physical boards. QEMU alone is insufficient.
- Before any flash/reconnect, capture each current clock's API epoch, uptime,
  source, and sync history against an external time reference. The PC's clock
  was unsynchronized in the earlier check. Preserve evidence before correction.
- Confirm the user is ready for automatic NTP correction before reconnecting:
  obtaining network access starts SNTP automatically in the current firmware.
- Follow the written guide to flash each identified device without resetting
  NVS or changing its scene card; provision Wi-Fi and read back LAN API state.
- Verify expected firmware/identity, station IP, a new NTP sync, clock accuracy
  within API/network measurement uncertainty, and persistence across restart.
  Leave physical visual acceptance explicit. Restore any temporary PC Wi-Fi
  changes and record the actual outcome, including incomplete steps.

## Decisions for discussion

1. **Delivery:** recommend standard firmware plus PowerShell provisioning.
   An immediate AP/web reconnection remains possible before this feature exists.
2. **Installer experience:** recommend an explicit optional Wi-Fi step after
   flashing, plus a standalone Wi-Fi-only command. Routine updates retain Wi-Fi.
3. **Time correction:** recommend preserving baseline skew evidence first, then
   allowing normal automatic NTP after the approved reconnect. This feature
   itself does not need a manual time-reset command.
4. **Release:** recommend a separately identified ESP32 candidate for physical
   validation before publication. Choose its version during release preparation;
   do not label the existing Windows candidate as ESP32 provisioning support.

## Completion criteria

A user can follow the guide from Windows, flash either board with the correct
standard image, enter Wi-Fi credentials over COM, verify its LAN API and NTP
state, and repeat an update without losing Wi-Fi or unrelated settings. The
same guide has been followed successfully on both physical clocks, with
redacted evidence saved locally. These physical completion criteria remain open.
