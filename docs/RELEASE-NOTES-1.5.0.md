# DMDClock v1.5.0

## ESP32-S3

- Adds first-class Waveshare ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1 support at
  640×172 with the shared 128×32 renderer at an exact 5× scale.
- Keeps the original Waveshare ESP32-S3-Touch-LCD-7 at 800×480 and 6× scale.
- Enables physical touch menus on both targets, including corrected AXS15231B
  coordinates and button mapping on the 3.49B.
- Uses the same scene library, timing, themes, information row, web remote, API,
  settings, Wi-Fi/NTP, MQTT, and Home Assistant integration on both displays.
- Updates the PowerShell flasher to discover and verify the correct target package
  when both board manifests are present in one GitHub release.

The 1024×600 Waveshare 7B and Waveshare 3.49B V1 are incompatible and remain
blocked. Select the exact physical board in the flasher; 3.49B DMDClock firmware
requires V2 / Rev1.1.

## Validation

- Both hardware targets build with ESP-IDF 5.5.2 and produce separate manifests,
  firmware ZIPs, and SHA-256 lists from the same source revision.
- Landscape349 QEMU acceptance covers clock, static and animated scenes, Basic,
  Gradient, Raster, Plasma, brightness, setup, information, and controls.
- Physical 3.49B validation covers display geometry, animation cadence, all colour
  modes, the information row, an illuminated 20-minute soak, and all touch buttons.
