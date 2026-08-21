# DMDClock v1.7.2

DMDClock v1.7.2 moves the ESP32-S3 clock fonts to the microSD card while
keeping the built-in 5x7 font as a permanent fallback.

## Highlights

- Discovers valid DotClk v1 `.fnt` files from `/dmd/fonts` during boot.
- Installs ALTERN8, FISHY, TREK, and TWILIGHT through the SD-card preparation
  workflow instead of embedding them in firmware.
- Adds a bounded parser and catalog, transactional font switching, legacy
  settings migration, and safe fallback behavior.
- Adds `GET /api/fonts` and exposes requested, active, fallback, and error font
  state through `/api/state`.
- Populates the web font selector from the valid boot catalog and reports when
  the requested font has fallen back to built-in 5x7.
- Preserves user fonts during SD preparation and verifies the canonical font
  copies by hash.
- Includes Windows installer, portable and standalone packages, an unsigned
  Apple Silicon macOS DMG, and firmware for both supported Waveshare displays.

## ESP32 Font Update

Run `RUNME-Install-DmdClockEsp32.ps1` and prepare the microSD card to install
the four canonical fonts. Custom DotClk v1 fonts can be placed directly in
`/dmd/fonts`. Font discovery happens only at boot, so restart the clock after
changing files on the card.

The built-in 5x7 font remains available without a card. Invalid or unavailable
SD fonts are omitted from the selector, and a failed selection leaves the
current renderer and persisted setting unchanged.

Supported boards are the Waveshare ESP32-S3-Touch-LCD-7 (800x480, N16R8) and
ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1 (640x172, N16R8). The 7B and 3.49B V1 are
not compatible.
