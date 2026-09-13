# PowerShell Stability TODO

This TODO assesses only these PowerShell files in the current working tree:

- `DMDClock.ps1`
- `Flash-DmdClockEsp32.ps1`
- `Prepare-DmdClockSdCard.ps1`
- `Reset-DmdClockSettings.ps1`
- `RUNME-Install-DmdClockEsp32.ps1`
- `DmdClock.Provisioning.psm1`

The focus is operational stability. The maturity labels are evidence-based and
do not claim physical hardware validation where only parsing, requirements
checks, or dry-runs were performed.

## Current evidence

- [x] All six files parse without PowerShell syntax errors.
- [x] `Flash-DmdClockEsp32.ps1`, `Prepare-DmdClockSdCard.ps1`,
  `Reset-DmdClockSettings.ps1`, and `RUNME-Install-DmdClockEsp32.ps1` pass all
  12 checks exposed by their `-CheckRequirements` paths and exit with code 0.
- [x] `DMDClock.ps1` accepts redirected option `5`, prints `Goodbye.`, and exits
  with code 0.
- [x] Empty or exhausted redirected menu input fails once with a concise
  selector/parameter message, without a null exception or retry loop.
- [x] A fully parameterized `RUNME-Install-DmdClockEsp32.ps1 -WhatIf` reports
  that the dry-run plan completed and no flash occurred.
- [x] `DMDClock.ps1` menu option 4 invokes the real Download Only orchestrator,
  which stages and verifies scenes, the portable tool, and supported firmware.
- [x] P0 validation on 2026-08-21: all six files parsed cleanly; the orchestrator
  and cancellation tests passed; the SD download-only acceptance test passed;
  a fully parameterized RUNME dry-run exited 0 with `no flash occurred`; and the
  existing staging manifest verified all 10 required artifacts.
- [ ] Four core files contain substantial uncommitted rewrites and
  `DMDClock.ps1` is currently untracked. Treat maturity as working-tree
  maturity until those changes receive focused validation.
- [x] PSScriptAnalyzer is installed and reports zero error-severity findings
  across the six scoped files (advisory warnings remain, chiefly intentional
  `Write-Host` use in interactive scripts).
- [ ] `Test-DmdClockComPorts.ps1` is stale after port helpers moved into the
  shared module; it still searches the flash script for `Get-ConnectedPorts`.
  Update that test before claiming injected COM-identity-change acceptance.

## Maturity assessment

| File | Maturity | Stability assessment |
| --- | --- | --- |
| `DMDClock.ps1` | Beta | Per-operation/fatal boundaries, EOF handling, result consumption, and real Download Only are implemented; broader interruption coverage remains. |
| `RUNME-Install-DmdClockEsp32.ps1` | Beta | Staging and result-aware completion reporting work; companion-script bootstrapping still needs transactional hardening. |
| `Flash-DmdClockEsp32.ps1` | Late beta | Hardware, manifest, hash, confirmation, and logging safeguards are substantial; outcome, interruption, and recovery behavior still need validation. |
| `Prepare-DmdClockSdCard.ps1` | Late beta | Disk identity, FAT32, path containment, idempotency, and atomic-copy controls are strong; redirected confirmation and interrupted-write behavior remain open. |
| `Reset-DmdClockSettings.ps1` | Late beta | The erase is narrowly scoped, cancellation/failure is explicit, and port identity is revalidated immediately before erase; injected COM-change proof remains. |
| `DmdClock.Provisioning.psm1` | Late beta | Shared validation, prompt EOF handling, and the operation-result contract are substantial; downloads, archive replacement, timeouts, and logging resilience need hardening. |

## P0 - Correct outcomes and destructive-operation safety

- [x] Establish one explicit operation-result contract for child scripts:
  `completed`, `cancelled`, `dry-run`, or `failed`.
- [x] Make `RUNME-Install-DmdClockEsp32.ps1` and `DMDClock.ps1` consume that
  contract instead of interpreting a normal child-script return as success.
- [x] Ensure standalone failures produce a nonzero exit code while the
  interactive menu may catch the failure, show the original evidence, and
  return to the menu.
- [x] Ensure cancellation and early-exit paths never produce flash, reset,
  card, install, or download completion messages.
- [x] Change the fully parameterized RUNME `-WhatIf` completion text to state
  that the dry-run plan completed and no flash occurred.
- [x] Make every shared prompt handle empty and exhausted redirected input
  without null exceptions or retry loops. When required selections are absent,
  fail with a concise message naming the required parameters.
- [x] Implement menu option 4 as a real Download Only operation that stages and
  verifies firmware for supported boards, the portable flash tool, and the
  selected scene payload before reporting completion.
- [x] In `Reset-DmdClockSettings.ps1`, revalidate the selected COM-port identity
  immediately before `erase_region` and refuse the erase if the device or port
  changed.
- [x] Make reset no-device, unmatched-port, rejected-confirmation, and other
  cancellation paths return an explicit non-success outcome without claiming
  that settings were reset.

## P1 - Transactional recovery and predictable automation

- [ ] Make companion-script acquisition version-consistent and
  integrity-checked. Download all required companions into a temporary set,
  validate them together, and replace the live set only after the complete set
  passes validation.
- [ ] Prevent a failed companion download from leaving a mixture of old and new
  scripts. Preserve the original files and original failure evidence.
- [ ] Add bounded connection and operation timeouts plus limited retry behavior
  for GitHub metadata and file downloads. Retry only transient failures and
  report the final URL, attempt count, and cause.
- [ ] Validate size, digest, and expected content before replacing an existing
  valid cached artifact. A failed refresh must leave the valid cache usable.
- [ ] Make archive replacement transactional: fully validate and extract into a
  sibling staging directory, retain the previous package until promotion
  succeeds, and restore or preserve it if promotion fails.
- [ ] Ensure provisioning-log creation, append, and finalization failures never
  mask the actual flash, reset, download, or SD-card result. Emit a warning
  while preserving the original outcome and error.
- [ ] Define redirected-input behavior explicitly. Redirected input must never
  implicitly approve a destructive `ShouldProcess` action; require all target
  selectors and an explicit automation confirmation policy.
- [ ] Preserve the first causal error through nested catch/finally cleanup,
  including the failing path, operation, native exit code, and available stack
  trace.

## P2 - Diagnostics and resilience coverage

- [ ] Replace swallowed serial-probe failures with bounded diagnostic records
  that identify the COM port and probe stage without turning an optional probe
  into a fatal error.
- [ ] Exercise SD-card removal, media becoming read-only, insufficient free
  space, and copy interruption. No completed manifest may be written unless all
  managed files were verified at their destinations.
- [ ] Bound archive extraction by entry count, total expanded bytes, and
  per-entry size in addition to the existing path-containment checks.
- [ ] Detect and reject unsupported archive entry types and retain traversal
  rejection for rooted paths, drive-qualified paths, and `..` segments.
- [ ] Review temporary-file cleanup after cancellation, terminating errors, and
  process interruption; cleanup must never target anything outside the
  operation's validated staging or temporary root.

## Acceptance gates

- [x] All six files pass PowerShell parser checks with zero errors.
- [x] PSScriptAnalyzer runs against only these six files with no errors or
  high-severity findings; any intentional suppression is narrow and documented.
- [x] Empty, blank, or exhausted redirected input exits clearly without a null
  exception, infinite prompt loop, or destructive action.
- [x] A fully parameterized RUNME `-WhatIf` makes no file, cache, serial-port,
  flash, hardware, or log changes and explicitly says that no flash occurred.
- [x] Download Only stages and verifies firmware, tools, scenes, and the staging
  manifest before it reports completion.
- [x] Child cancellation never becomes an install-success message. Standalone
  failures return nonzero; the interactive menu reports the original error and
  remains usable.
- [ ] Injected download, extraction, cache-promotion, log-write, SD-copy, and
  COM-port-change failures preserve the previous valid state and the original
  error evidence.
- [ ] Safe `-TestRoot` scenarios below a dedicated temporary directory prove
  initial copy, idempotent rerun, repair of a damaged managed file, preservation
  of unrelated files, failure cleanup, and no writes outside the test root.
- [ ] Flash and reset tests prove that a COM-port identity change immediately
  before the destructive command is refused.
- [ ] Physical flash/reset validation is tracked separately for each available
  supported hardware variant. Parser checks, mocks, emulation, requirements
  checks, and dry-runs are never recorded as physical hardware proof.

## Completion rule

This TODO is complete only when every applicable acceptance gate has current
evidence. Any unavailable hardware variant or intentionally deferred scenario
must remain unchecked and state exactly what proof is missing.
