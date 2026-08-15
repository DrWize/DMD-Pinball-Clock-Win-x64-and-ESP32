# Local SCN library

Place `.scn` animation files in this directory. DMDClock uses `./scenes` as its default library and scans subdirectories recursively.

Animation files in this directory are intentionally ignored by Git. Personal builds copy the local contents into `scenes/` beside the application executable, and later builds preserve that directory.

`scene-metadata.json` is the exception: it is tracked, validated, and copied into
every published application, screensaver, and installer package. Keep metadata
changes separate from proprietary `.scn` files and document reliable sources in
the corresponding GitHub request.

The same catalog is installed as `/dmd/scenes/scene-metadata.json` on an ESP32
card. Production ESP32 firmware scans the flat `/dmd/scenes` directory and uses
the catalog for game, scene title, manufacturer, and first-release year while
keeping timing and masks authoritative in each SCN file.

## Shared download catalog

`catalog.json` is the single scene-library discovery document for Windows x64,
macOS ARM64, and ESP32-S3. Its JSON Schema is
`scene-pack-catalog.schema.json`. Available archives must use HTTPS, a pinned
source revision, an exact byte size, and SHA-256. An unavailable pack must keep
its download URL and checksum null.

The selectable **Original DotCLK-Orig** entry (2,324 scenes) remains hosted by its
official `sigmafx` source. Preferred **DMD-Large** (2,416 scenes, including every
original scene) is hosted as the versioned GitHub Release
`scene-pack-v2026.08.10`, with its exact size and SHA-256 recorded in the
catalog. Scene ZIPs remain release assets instead of Git history.

The Avalonia downloader used by Windows and macOS installs the choices in
separate `DotCLK-Orig` and `DMD-Large` managed directories. The Windows microSD card
preparation script uses the same catalog IDs, stages and verifies the selected
archive, and keeps custom scenes when switching libraries.
