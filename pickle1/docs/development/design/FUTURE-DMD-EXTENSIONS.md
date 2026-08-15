# Future DMD Extensions support

> Parked future plan: active development is currently limited to the classic 128×32 display and four-bit monochrome SCN files. Serum, full color, larger resolutions, and DMD Extensions must not be connected to the main application until this scope is explicitly changed.

`freezy/dmd-extensions` is a future technical reference, not a dependency of the current build:

https://github.com/freezy/dmd-extensions

DMDClock's current goal remains stable playback of DotClk SCN files at 128×32 with four-bit intensity. The core should later be extensible without breaking this format.

## Planned architecture

1. Replace fixed 128×32 assumptions in the general image core with a versioned frame format that specifies width, height, pixel/color format, and stride.
2. Retain an optimized compatibility path for current 128×32 SCN files and their transparency masks.
3. Add color formats incrementally: four-bit monochrome, indexed palette, and RGB24.
4. Add explicit scaling modes: integer scaling, fit, fill, and stretch. Test at least 128×32, 192×64, and 256×64.
5. Separate frame source, composition, scaling, and output so Windows, Raspberry Pi, ESP32 packages, and possible physical DMD output can share test vectors.
6. Investigate an optional adapter for DMD Extensions, its network interface, or supported devices only after the local color renderer is stable.

## Color and media

The following should be investigated separately and remain optional:

- full RGB graphics and RGB24 output
- Serum colorization and VNI/PAL/PAC compatibility
- PNG, GIF, and other media formats
- network streaming to or from external DMD devices
- hardware such as PIN2DMD, Pixelcade, PinDMD, and ZeDMD

## Serum and ColorizingDMD

The plan also uses the following workflow guide:

https://www.pincabpassion.net/t15414-comprehensive-tuto-about-colorizingdmd

The guide describes Serum/cRom as a two-stage workflow:

1. **Identification:** an incoming two- or four-bit DMD frame is matched against known frames. Comparison masks ignore dynamic areas such as scores, balls, and player data. Masks should be reused where possible because many comparisons consume CPU time.
2. **Colorization:** the identified frame receives a palettized six-bit image with up to 64 RGB colors. Dynamic original pixels are colorized in real time through palette sets and area masks.

Serum features to consider in a future optional layer:

- palettes of up to 64 colors per relevant scene/frame
- comparison masks for static identification areas
- dynamic color sets and masks for scores and other changing text
- sprites with limited detection areas for moving objects
- fixed backgrounds beneath dynamic content
- timed color rotations and gradients
- image and video import for creating palettized frames
- frame dumps with timestamps as reproducible test data
- preview of original and colorized output using real frame timings

### Suggested implementation order

Status: an isolated prototype for steps 1–4 exists and is tested in the cross-platform core. It is frozen, is not used by the application UI, and must not be extended or connected to an external `.cRom` importer while the classic-display track remains active.

1. Create test vectors from synthetic frame dumps; do not distribute ROM data or third-party colorizations without clear rights.
2. Implement a standalone six-bit palette frame and RGB24 conversion.
3. Implement deterministic identification using comparison masks and diagnostics for zero, one, or multiple matches.
4. Add static palette colorization and fallback to the original monochrome frame when no rule matches.
5. Add dynamic palette sets and area masks.
6. Then add backgrounds, color rotations, and sprites with explicit CPU budgets.
7. Verify results against DMD Extensions in a separate integration-test profile.
8. Add `.cRom`/Serum import only after format versions, licensing, and compatibility are documented with distributable test files.

### Performance and portability

A 64-color palette frame is especially interesting for Raspberry Pi and future serial DMD output because it requires less bandwidth than RGB24. The desktop renderer can expand palette indices to RGB24 late in the rendering pipeline, while ESP32-S3 packages can retain the palette format. Matching, sprites, and color rotations should be measured independently so one slow rule cannot stop the clock or animation playback.

### Content and distribution

The Serum editor and format implementation use GPL-2.0. The guide also specifies attribution and sharing conditions for created colorizations. Each colorization file must therefore record its origin, license, author, and distribution status in the library manifest. The application should support locally added files without automatically including them in the installation.

## License boundary

DMD Extensions uses GPL-2.0. Before libraries, DLLs, or source code are integrated, the project's own license must be decided and the consequences reviewed. A separate process or documented protocol may be a better integration boundary, but this must also be verified before distribution.
