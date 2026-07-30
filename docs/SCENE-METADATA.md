# Scene metadata

`scenes/scene-metadata.json` supplements SCN files with information that is not
stored in the SCN format itself. The verified baseline file is tracked in Git and
included in every portable ZIP, standalone package, screensaver package, and
installer. Proprietary `.scn` animation files remain excluded.

```json
{
  "schemaVersion": 1,
  "prefixes": [
    { "prefix": "got", "game": "Game of Thrones", "manufacturer": "Stern", "year": 2015,
      "dateManufactured": "2015", "players": 4, "machineType": "SS", "theme": "Licensed Theme" }
  ],
  "files": [
    { "path": "got01.scn", "title": "Optional scene title" }
  ]
}
```

An exact entry under `files` takes precedence over a prefix rule. Paths are relative to the selected animation directory, and `/` is used on Windows as well. The `title`, `game`, `manufacturer`, `year`, `dateManufactured`, `players`, `machineType`, and `theme` fields are optional. Unknown files continue to work and are displayed using their filename.

Metadata should only be added when the information is reliable. The application must not guess a game from generic names such as `RD0001.scn`.

Release years appear in the Scene Reviewer only when one exact, verified year is
known for the selected game identity. Missing or ambiguous years are intentionally
hidden.

Metadata corrections should be proposed through a GitHub issue or pull request
with the game, scene path or prefix, corrected value, and a reliable evidence
link. A future in-app updater remains on the roadmap; current metadata updates
arrive with a new application build or a reviewed repository update.

## RD index mapping

When `external/DotClk-Resources/RD Index.txt` is available, all local `RD####.scn` files can be mapped deterministically with:

```powershell
./scripts/Map-RdScenes.ps1
```

The script preserves non-RD entries, prefix metadata, and supplemental fields such as manufacturer and year on existing RD entries in `scenes/scene-metadata.json`. It refreshes the RD mapping fields and skips index rows whose SCN file is not installed. The RD index provides a game key and numbered sequence but no descriptive animation title, so generated entries use the normalized game name and `Scene NNN` rather than guessing.

Four RD groups deliberately use the base game name in both the RD mapping and metadata list. Edition labels such as Pro, Premium, and LE are intentionally omitted:

| RD range | Displayed game name |
| --- | --- |
| `RD0081–RD0119` | Avengers |
| `RD0122–RD0125` | Batman |
| `RD0792–RD0845` | Indiana Jones |
| `RD1566–RD1603` | Star Trek |

The same information is written to `rdIndexGameNotes` in the generated metadata so it remains attached to the mapping. The runtime safely ignores this documentation field.
