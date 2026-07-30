# DMDClock secondary-storage root

The canonical project and metadata source is
[DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32).

This directory models `/dmd` at the root of the ESP32-S3 microSD/TF card. Copy
the contents of this `dmd` directory to the card as `/dmd`; do not copy the
project's enclosing `sdcard` directory.

The clock must still boot and show a basic clock when the card is absent,
unmounted, corrupt, or incompatible. Internal flash therefore retains the
firmware, bootloader, partition table, NVS settings, the embedded web remote,
and one built-in bitmap font. Production firmware embeds no SCN files and
stays in clock mode when no valid card scene is available.

## Layout

| Card path | Purpose |
| --- | --- |
| `/dmd/scenes` | User/downloaded `.scn` library and shared `scene-metadata.json` |
| `/dmd/fonts` | Validated DotClk bitmap fonts and future converted font assets |
| `/dmd/plasma` | Plasma palettes, presets, lookup tables, and optional textures |
| `/dmd/web` | Version-matched non-recovery web assets |
| `/dmd/config` | Editable settings backup and deterministic content manifests |
| `/dmd/backups` | User-requested settings and library-index backups |
| `/dmd/logs` | Bounded rotating diagnostic logs |
| `/dmd/cache` | Rebuildable scene/font indexes, thumbnails, and downloaded metadata |
| `/dmd/downloads` | Temporary verified downloads before atomic installation |

The firmware mirrors web-editable settings to
`/dmd/config/settings.json`, including the Wi-Fi password needed for a complete
restore. Treat the card and every copied settings file as sensitive. Future
administrator credentials and session secrets must remain protected and must
not be exported in plaintext.

Firmware code cannot execute from this directory. Update packages may be staged
under `/dmd/downloads`, but installation must still write a validated internal
OTA application partition.

## Offload order

1. The production build indexes every valid flat `.scn` file in `/dmd/scenes`
   and embeds no fallback scene. QEMU embeds an 11-scene compatibility corpus
   and an automatically generated projection of the shared metadata catalog for
   deterministic testing.
   Copy the repository's `scenes/scene-metadata.json` to
   `/dmd/scenes/scene-metadata.json`; this is the same schema-1 catalog used by
   Windows. The firmware releases the parsed JSON after resolving its compact
   in-memory scene records.
2. Store all additional scenes and generated scene indexes on the card.
3. Store DotClk and converted font packs under `/dmd/fonts`; retain only the
   built-in 5×7 fallback font internally. Never embed full TTF/OTF collections.
4. Keep the compact procedural Plasma renderer in firmware, but load palettes,
   presets, lookup tables, and optional textures from `/dmd/plasma`.
5. Keep a minimal recovery web page internally and allow the version-matched
   full interface to load from `/dmd/web`.
6. Put settings backups, logs, thumbnails, indexes, catalog metadata, temporary
   downloads, and content snapshots on the card because they are
   non-boot-critical and can grow or be regenerated.

The card writer must use temporary files followed by same-filesystem rename for
manifests, indexes, downloads, and settings exports. Cache and log failures must
not stop the clock or display refresh.

Use `scripts/esp32/Prepare-DmdClockSdCard.ps1` to validate and idempotently
prepare an already-formatted FAT32 card. The script preserves unrelated scenes,
repairs managed files, installs the shared metadata, and writes a SHA-256
manifest without formatting the volume.
