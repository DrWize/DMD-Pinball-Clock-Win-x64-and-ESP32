# DMDClock for Windows

Download the setup EXE or standalone ZIP from the
[latest release](https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest).
Use Windows 11 x64. The packages include the required .NET runtime.

## Install and start

Run the setup EXE for a per-user installation, or extract the standalone ZIP to
a writable folder and run `DmdClock.App.exe`. The installer also supplies
`DMDClock.scr` and optional desktop, sign-in startup, and screensaver tasks.
Ordinary updates retain settings in `%LOCALAPPDATA%\DmdClock`.

The app works as a clock without animations. Right-click the display and choose
**Download scenes…**, or select an existing folder containing `.scn` files.
Use **Review and choose scenes…** to select the games and scenes you want.

## Display and playback

Use the right-click menu to choose clock format, fonts, colours, brightness,
glow, hot core, and clock/animation cycling. F11 toggles fullscreen.
Normal playback automatically uses verified scene-level brightness metadata;
custom scenes without matching metadata keep their original levels.

Windows v1.9.0 uses 100 ms for stored 10 ms regular delays and missing/zero
regular timing. Other explicit delays and opening/closing holds are preserved.
Each frame receives its full hold after submission, without catch-up skipping.
This is a visual playback policy, not a reconstruction of pinball-machine timing.

![Last Action Hero with mapped levels](screenshots/v1.9.0/windows-last-action-hero-frame-1.png)

## Diagnostics and API

Space pauses/resumes. Comma/period or Left/Right pause and step through frames.
Enable debug timing to inspect delays, duration, measured updates, and skips;
Up/Down adjust debug speed between 0.1x and 4.0x.

The optional **LAN API settings…** dialog enables bearer-token HTTP access
(default port 17891). It is disabled by default and does not add a firewall rule.
The API supports state, playback controls, scene selection within the current
library, and synchronized screenshots. See the [API guide](development/WINDOWS-API.md).

## Recovery

If animations do not appear, confirm the scene folder and allowed-scene selection.
Unknown filenames still play without metadata. For a port-in-use API error,
choose an unused port or close the other listener. Never share the API token
in screenshots or public reports.

Uninstall through Windows Installed apps. The installer preserves user settings
and restores the prior screensaver when it still owns the active selection.
