# DMDClock Provisioning — Code Improvement TODO

Redundancy analysis completed 2026-08-19. This file tracks implementation tasks.

## P1 — RUNME Installer Test-Run Expectations

Tested 2026-08-21. `RUNME-Install-DmdClockEsp32.ps1` is the orchestration entry
point. `DMDClock.ps1` is a separate unified interactive menu.

- [x] `-CheckRequirements` reports that all 12 SD-card and firmware checks pass
- [x] A fully parameterized `-WhatIf -SkipCard` run verifies the staged firmware and esptool inventory, prints the flash plan, and performs no writes
- [ ] A non-interactive `-WhatIf` run must not enter the microSD wizard or call `Read-Host`; currently it fails in `Prepare-DmdClockSdCard.ps1` when redirected input returns `$null`
- [ ] A non-interactive `-WhatIf -SkipCard` run without explicit board choices must not enter the firmware wizard or call `Read-Host`; currently it fails in `Flash-DmdClockEsp32.ps1` when redirected input returns `$null`
- [ ] Decide and document the non-interactive defaults: require explicit selection parameters with a clear validation error, or print the available choices and stop successfully
- [ ] Ensure every `-WhatIf` completion message says that the plan completed and does not claim that flashing completed
- [ ] Add regression coverage for redirected/null input through the RUNME orchestrator
- [ ] Re-run the default, `-SkipCard`, and fully parameterized dry-run scenarios and verify that none downloads, writes a card, opens a serial port, flashes, or resets settings

## P1 — DMDClock Unified Menu Test-Run Expectations

- [x] `DMDClock.ps1`, its three delegated scripts, and the provisioning module exist and parse without errors
- [x] All four provisioning-module commands referenced by the menu are exported
- [x] In a normal terminal, the banner and five choices render and option 5 prints `Goodbye.` and exits with code 0
- [x] Options 1–3 delegate to the SD preparation, firmware flash, and settings reset scripts respectively
- [x] Skip `Clear-Host` when output is redirected; redirected menu input can select option 5 and exit cleanly
- [x] Catch operation failures, show the original message and stack trace, and return to the main menu
- [x] Catch initialization and menu failures, show a fatal error, and exit with code 1
- [ ] Make option 4 perform the advertised download-only workflow; currently it only runs a network requirements check and then claims that files were downloaded
- [ ] Verify option 4 stages the required SD library, both supported firmware packages, and esptool without preparing a card or flashing hardware
- [ ] Add a safe test mode or regression harness that can exercise every menu route without downloads, card writes, serial-port access, flashing, or settings reset
- [ ] Decide whether `DMDClock.ps1` or `RUNME-Install-DmdClockEsp32.ps1` is the documented primary end-user entry point and make their responsibilities unambiguous

## P1 — Serial Banner Reading Duplication

- [x] Move `Read-DmdClockSerialBuffer` from Flash into `DmdClock.Provisioning.psm1`
- [x] Move `Read-DmdClockSerialBanner` from Flash into `DmdClock.Provisioning.psm1`
- [x] Move `Get-DmdClockBoardProbe` from Flash into `DmdClock.Provisioning.psm1`
- [x] Rewrite `Get-DmdClockResetDeviceProbe` (Reset) to call the shared functions instead of inline duplication
- [x] Export all three new module functions
- [x] Verify Reset still probes correctly (DTR/RTS timing, native USB JTAG path, banner regex)

## P1 — Device Table Display Duplication

- [x] Create unified `Show-DmdClockDeviceTable` in module (accepts rows with optional `App`, `Signals` columns)
- [x] Replace `Show-DeviceTable` in Flash to call the unified function
- [x] Replace `Show-ResetDeviceTable` in Reset to call the unified function
- [x] Export the new module function

## P1 — Esptool Release Resolution Duplication

- [x] Extract `Get-DmdClockEsptoolReleaseAsset` helper in module (GitHub query + v5 asset filtering + digest extraction)
- [x] Refactor `Get-DmdClockPortableEsptool` (module) to use the new helper
- [x] Refactor the esptool staging block in `Invoke-FirmwareDownloadOnly` (Flash) to use the new helper
- [x] Export the new function

## P2 — try/catch/finally Error Logging Wrapper

- [ ] Create `Invoke-DmdClockWithLogging` in module (accepts ScriptBlock + Operation + LogPath ref)
- [ ] Refactor Flash main try/catch/finally to use it
- [ ] Refactor Prepare main try/catch/finally to use it
- [ ] Refactor Reset main try/catch/finally to use it

## P2 — Module Import Boilerplate

- [ ] Decide: keep explicit import vs switch to `#Requires -Module` (requires `$env:PSModulePath` change)
- [ ] If keeping explicit import: no change needed (low-value cleanup)

## P2 — Config Extraction Pattern

- [ ] No action — intentional readability pattern. Document in AGENTS.md if desired.

## P3 — ZIP Extraction Variants

- [ ] No action — each serves a distinct verification purpose.

## P3 — Companion Script Download Pattern

- [ ] No action — different lifecycle contexts.
