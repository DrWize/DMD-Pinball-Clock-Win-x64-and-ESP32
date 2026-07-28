# Plasma effect experiment

The `Plasma` appearance preset uses a classic four-wave plasma to color the lit
dots of the existing 128 × 32 DMD frame. Zero-intensity dots remain black and the
source frame's 4-bit intensity continues to control brightness, so scene and clock
shapes are preserved.

## Shared algorithm

`DmdClock.Core.Rendering.PlasmaField` produces a 7-bit palette index from:

- horizontal, vertical, and diagonal sine waves;
- an approximate radial wave;
- a shared 8-bit animation phase.

The per-pixel path uses integer addition, multiplication, bit masking, and a
256-entry signed sine lookup table. It performs no trigonometry and allocates no
memory while sampling. The desktop renderer maps the result to a cached cyclic
128-color palette. Eight built-in palettes are available:

- **Neon:** purple, blue, cyan, and magenta;
- **Lava:** deep red, red, orange, and yellow;
- **Ocean:** navy, blue, cyan, and ice white;
- **Aurora:** deep purple, violet, green, and yellow-green;
- **Toxic:** dark green, bright green, acid yellow, and pale yellow;
- **Vapor:** purple, violet, magenta, and cyan;
- **Solar:** deep red, red-orange, orange, and pale yellow;
- **Arctic:** navy, blue, cyan, and ice white.

Choose **Appearance → Color theme → Plasma palette → Custom…** to edit the four
color stops. DMDClock interpolates between those colors and loops from the fourth
back to the first. Custom colors are stored in `settings.json` and apply
simultaneously to the main app, screensaver, preview, and Scene Reviewer.

The phase completes one cycle every eight seconds. Main app, screensaver, preview,
and all Scene Reviewer tiles use the same phase source.

## Cycle speed

Choose **Appearance → Color theme → Plasma speed** to select:

- **Slow:** 16 seconds per complete cycle;
- **Normal:** 8 seconds;
- **Fast:** 4 seconds;
- **Very fast:** 2 seconds;
- **Custom:** 1–60 seconds in 0.25-second steps.

The duration is stored as an integer `plasmaCycleMilliseconds` value. Pause freezes
the monotonic elapsed timer, so resuming continues from the same phase.

## ESP32 target

The implementation and release sequence is tracked in the
[ESP32-S3 roadmap](ESP32-S3-ROADMAP.md). Shared lookup tables, palettes, and test
vectors must be generated from canonical definitions so Windows and ESP32 cannot
drift independently.

The field deliberately uses types and operations that translate directly to C or
C++ on an ESP32:

```cpp
uint8_t phase;
int8_t sineTable[256];
uint8_t paletteIndex = samplePlasma(x, y, width, height, phase);
```

For firmware, store the sine table and 128-color RGB palette in flash (`PROGMEM`) and advance
the phase from `millis()` or a fixed frame tick. Apply the source DMD intensity
after looking up the RGB color. FastLED can provide the final palette lookup and
brightness scaling, but the field calculation does not depend on FastLED.

The firmware exports the Windows-generated lookup table as a fixed constant and
checks the four shared vectors during display initialization. This avoids differences
in startup-time floating-point sine generation and proves that Windows and ESP32
produce identical palette indices. The core test suite already records four
reference vectors for the 128 × 32 matrix.

Only the four RGB color stops need to be transferred when a user changes the
palette. The ESP32 can regenerate the same 128 interpolated colors locally, or the
desktop app can send the expanded palette.

The ESP32 uses the same integer timing expression:

```cpp
phase = ((millis() % cycleMilliseconds) * 256) / cycleMilliseconds;
```

Use an unsigned 64-bit intermediate for the multiplication if cycle durations are
later extended beyond the current 60-second maximum.
