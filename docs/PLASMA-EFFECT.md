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
purple, blue, cyan, and magenta palette.

The phase completes one cycle every eight seconds. Main app, screensaver, preview,
and all Scene Reviewer tiles use the same phase source.

## ESP32 target

The field deliberately uses types and operations that translate directly to C or
C++ on an ESP32:

```cpp
uint8_t phase;
int8_t sineTable[256];
uint8_t paletteIndex = samplePlasma(x, y, width, height, phase);
```

For firmware, store the sine table and RGB palette in flash (`PROGMEM`) and advance
the phase from `millis()` or a fixed frame tick. Apply the source DMD intensity
after looking up the RGB color. FastLED can provide the final palette lookup and
brightness scaling, but the field calculation does not depend on FastLED.

Before firmware integration, export the Windows-generated lookup tables as fixed
constants and use matching test vectors on both platforms. This avoids differences
in startup-time floating-point sine generation and proves that Windows and ESP32
produce identical palette indices. The core test suite already records four
reference vectors for the 128 × 32 matrix.
