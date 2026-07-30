# Install DMDClock on Windows

This is the shortest supported path for Windows 10 or Windows 11 x64. You do not
need Git, Visual Studio, PowerShell, or a separate .NET installation.

## 1. Download

Open the [latest DMDClock release][latest-release], expand **Assets**, and download
the file ending in `win-x64-setup.exe`.

The installer is not Authenticode-signed. Windows may therefore show a
reputation warning even when the file is unchanged. Compare the download against
the release `SHA256SUMS.txt` if you want to verify it. Do not bypass a warning for
a file obtained anywhere other than this project's release page.

## 2. Install

1. Double-click the setup EXE.
2. Keep the default per-user installation folder.
3. Select a Desktop shortcut, start with Windows, or screensaver activation only
   if you want those options.
4. Select **Install**, then **Finish**.

The installer needs no administrator rights and preserves settings and scene
choices during an upgrade.

![DMDClock running after installation](screenshots/install/windows-clock.png)

## 3. Add the pinball scenes

1. Right-click the DMD display.
2. Choose **Download DotClk scenes…**.
3. Review the source and choose **Download**.
4. When scanning finishes, use **Review and choose scenes…** to disable games or
   individual scenes you do not want.

![The DMDClock right-click controls](screenshots/setup/settings-menu.png)

The scenes are stored under `%LOCALAPPDATA%\DmdClock\Scenes\DotClk`, outside the
program files. They are not embedded in the installer.

## 4. Everyday use

- Right-click the display for all clock, scene, colour, and screensaver controls.
- Press `T` for the clock, `D` for the date, `N` for the next scene, and `F11`
  for fullscreen.
- A small startup notice appears when a newer GitHub release is available.
  DMDClock never downloads or installs an update automatically.

Settings, review choices, the scene index, and logs stay in
`%LOCALAPPDATA%\DmdClock`. Installing a newer setup EXE over the existing version
keeps that data.

For the complete walkthrough, including the screensaver and troubleshooting, see
the [Windows user setup](USER-SETUP.md).

[latest-release]: https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest
