# C64-inspired raster themes

These appearance concepts keep the original 128×32 four-bit DMD frame intact. Color is applied only by the desktop renderer, so SCN parsing and animation compatibility are unchanged.

## Design lessons

- Classic C64 raster bars change border or background color by raster line. For DMDClock, the equivalent is selecting a palette entry from the dot's vertical row.
- Mirrored ramps from dark to bright and back create a rounded luminous bar.
- Interlacing alternates dark blue with lighter palette entries to suggest intermediate shades without introducing black lines.
- Extruded patterns repeat portions of a ramp and remove the brightest entry on later repetitions to create depth without black separators.
- Color-table rotation can animate a raster bar smoothly. DMDClock should use a slow movement rather than rapid full-frame switching.
- Rapid switching can create perceived colors, but combinations with unequal luminance visibly flicker. It should remain an optional accessibility-sensitive experiment, not a default theme.

## Implemented static themes

The following themes use a C64-like fixed 16-color RGB palette and map the selected ramp to the 32 DMD rows:

1. Blue round raster
2. Red round raster
3. Earthtone raster
4. Metal raster
5. Interlaced blue
6. Extruded cyan
7. C64 rainbow

They are available under **Appearance → Color theme**. The experimental Secret
Purple Mix is intentionally not implemented.

![C64 blue round raster theme](screenshots/colors/c64-blue-round.png)

![C64 rainbow theme](screenshots/colors/c64-rainbow.png)

## Recommended implementation order

1. Blue round bar, static.
2. C64 rainbow, static.
3. Extruded cyan, static.
4. Optional slow vertical palette roll with configurable speed.
5. Optional interlaced/dithered patterns after testing at small window sizes.

## Sources

- Daniel Krajzewicz, [Stretching the C64 Palette](https://www.krajzewicz.de/blog/stretching-the-c64-palette.php)
- Aaron Bell, [Secret colours of the Commodore 64](https://www.aaronbell.com/secret-colours-of-the-commodore-64/)
- Codebase64, [Demo coding introduction – Raster Bars](https://codebase.c64.org/doku.php?id=vic:demo:demo_coding_introduction#raster_bars)
- Codebase64, [Overlapping Raster Bars](https://codebase.c64.org/doku.php?id=base:overlapping_raster_bars)
- C64-Wiki, [Raster interrupt](https://www.c64-wiki.com/wiki/raster_interrupt)
