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
