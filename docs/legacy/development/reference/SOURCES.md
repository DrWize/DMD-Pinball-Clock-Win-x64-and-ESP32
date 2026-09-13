# Original resources and references

This file preserves important project links between work sessions. The project's README, documentation, and PowerShell scripts may link to the original resources. External files should be downloaded locally and must not be committed to this GitHub repository.

## Links provided by the user

- Dr Pinball: https://www.drpinball.co.uk/
- DotClk Resources: https://github.com/sigmafx/DotClk-Resources — source of the
  embedded `ALTERN8.fnt`, `FISHY.fnt`, `TREK.fnt`, and `TWILIGHT.fnt` files at
  commit `11211af85a2ade66d05d961839773a05a01bddcc`; upstream currently has no
  explicit license file
- Modern Hackerspace DMDClock: https://gitlab.com/modernhackerspace/dmdclock
- Build and usage instructions (PDF): https://gitlab.com/modernhackerspace/dmdclock/-/blob/master/DMD%20matrix%20build%20and%20Instructions.pdf?ref_type=heads
- Wikipedia list of pinball machines: https://en.wikipedia.org/wiki/List_of_pinball_machines — primary source for game manufacturer and release-year data in `scene-metadata.json`.
- Internet Pinball Database collection list: https://www.ipdb.org/lists.cgi?puid=45565&list=games — supporting source for resolving title variants and for additional manufacturing date, player count, machine type, and theme data.

## Additional technical references

- Original DotClk firmware: https://github.com/sigmafx/DotClk — reference for storyboards, blanking, transparency masks, and clock layers
- Original DotClk support tools: https://github.com/sigmafx/DotClk-Support — reference font and scene editors
- DMD Extensions: https://github.com/freezy/dmd-extensions — future reference for varying DMD resolutions, RGB graphics, colorization, scaling, network streaming, and physical DMD output. The project uses GPL-2.0; its license and integration boundary must be reviewed before code or binaries are reused.
- Comprehensive ColorizingDMD tutorial: https://www.pincabpassion.net/t15414-comprehensive-tuto-about-colorizingdmd — future reference for the Serum workflow with frame dumps, comparison masks, 64-color palettes, dynamic colorization, sprites, backgrounds, and color rotations
- ColorizingDMD/Serum editor: https://github.com/SerumColor/ColorizingDMD — official editor and format implementation under GPL-2.0
- PinScreen for Windows: https://github.com/davidvanderburgh/pinscreen
- Inter font: https://github.com/rsms/inter — distributed with the application under the SIL Open Font License 1.1

## Local resources

Local location: `external/`

The directory is ignored by Git. Run the repeatable download script from the repository root:

```powershell
./scripts/Get-OriginalResources.ps1
```

By default, the script downloads only missing repositories and leaves existing copies unchanged. Use `-Update` for fast-forward-only updates, `-Redownload` to replace clean existing copies with fresh shallow clones, or `-Resource DotClk-Resources` to select one or more named resources. `-WhatIf` previews clone, update, and redownload operations.

The script refuses to update dirty repositories or directories whose `origin` does not match the official catalog. It reports added, changed, deleted, and renamed files, and writes reproducibility data to the ignored files `external/original-resources-lock.json` and `external/original-resources-last-update.json`.

Network failures and changed repository locations are reported per resource. Other successfully processed repositories remain usable, and the report records the partial failure.
