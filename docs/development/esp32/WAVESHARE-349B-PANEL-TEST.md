# Waveshare 3.49B V2 physical panel diagnostic

This standalone ESP-IDF application qualifies the physical 640x172 AXS15231B
panel before the DMDClock backend is enabled. It is only for V2 hardware marked
`Rev1.1` or `V2`; it is not DMDClock firmware.

The display cycles through solid red, green, blue, black, and white frames for
two seconds each, then shows the grid for eight seconds. The grid contract is:

- red top-left, green top-right, blue bottom-left, white bottom-right;
- yellow outside border;
- cyan lines every 64 horizontal and 32 vertical pixels;
- magenta horizontal and vertical center lines.

Each stage and completed cycle is logged over USB Serial/JTAG. The PowerShell
runner validates those markers, rejects crash output, and records a JSON report
plus the complete serial log under `output/esp32/reports/physical-349b`.

Preview the complete build and hardware checks without writing:

```powershell
.\scripts\esp32\Test-DmdClockPhysical349B.ps1 `
  -Port COM5 -BoardRevision V2 -ConfirmHardware 3.49B `
  -DurationMinutes 1 -WhatIf
```

Remove `-WhatIf` for a one-minute smoke test. For the P5 soak gate, use
`-DurationMinutes 20`. The runner requires a final case-insensitive `FLASH`
confirmation because the diagnostic replaces internal flash and settings. It
does not touch the TF card.

Serial automation cannot prove what the LCD physically shows. Observe the
solid colors and grid throughout the run, checking orientation, RGB order,
tearing, and corruption against the recorded visual checklist.
