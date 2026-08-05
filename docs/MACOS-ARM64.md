# macOS Apple Silicon plan

## Goal and scope

Deliver DMDClock as a normal native-feeling macOS application for Apple Silicon.
The first supported package provides the clock, scene playback, settings, Scene
Reviewer, windowed mode, and fullscreen mode. It does not claim native macOS
screensaver integration.

The existing Avalonia application already cross-publishes successfully for
`osx-arm64`. The remaining work is bundle construction, Mac-specific validation,
signing, notarization, and distribution rather than a UI or rendering rewrite.

## Current evidence

- `dotnet publish -c Release -r osx-arm64 --self-contained true` succeeds from
  the Windows checkout.
- The output contains the ARM runtime plus Avalonia, Skia, HarfBuzz, and Apple
  native libraries.
- Direct `user32.dll` calls are isolated to the Windows screensaver preview host
  and guarded with `OperatingSystem.IsWindows()`.
- The raw publish is not a distributable Mac application: it has no `.app`
  bundle, `Info.plist`, `.icns`, code signature, notarization ticket, or Mac
  launch test.

## Phase 1 — repeatable unsigned application bundle

- Build only `osx-arm64`; Intel and universal binaries are out of scope until an
  Apple Silicon build has been exercised on hardware.
- Publish self-contained Release output into
  `DMDClock.app/Contents/MacOS`.
- Add `Contents/Info.plist`, `Contents/Resources`, the stable bundle identifier
  `io.github.drwize.dmdclock`, version/build metadata, and the current 512 px PNG
  as a temporary icon resource.
- Produce a versioned ZIP and `build-info.json` below
  `output/current/osx-arm64`.
- Mark the artifact explicitly as unsigned, unnotarized, and not release-ready.
- Keep the existing Windows build and release scripts unchanged.

Phase 1 exit: the bundle is structurally complete, the metadata matches the
source revision and version, and the published native libraries are present.
It is still a developer preview until it launches successfully on a Mac.

The `Build macOS release asset` GitHub Actions workflow performs this phase on a
`macos-14` runner, verifies ARM64 executable permissions and bundle contents,
creates and mounts a genuine DMG with `hdiutil`, and can attach the unsigned
developer preview plus metadata and checksums to an existing release.

## Phase 2 — physical Apple Silicon validation

Run on the oldest supported Apple Silicon macOS version and one current version:

- restore executable permissions after transfer and launch from Finder;
- verify normal, borderless, and fullscreen windows on one and multiple displays;
- verify Metal/Skia rendering, Plasma, Hot-core, clocks, dates, and SCN playback;
- verify mouse, Control-click, keyboard, file/folder pickers, and Scene Reviewer;
- verify embedded/external fonts and translations;
- verify settings, logs, and library state remain below
  `~/Library/Application Support/DmdClock`;
- verify browser links, release checks, and scene downloading;
- verify sleep/wake, display reconnect, repeated launch, and clean exit;
- confirm no Windows-only screensaver controls are presented as functional Mac
  integration.

Phase 2 exit: no application data is written inside the signed app bundle, all
primary workflows pass on real ARM hardware, and defects are captured as focused
cross-platform fixes rather than Windows regressions.

## Phase 3 — signing and notarization

- Replace the temporary PNG with a proper multi-resolution `.icns` generated and
  visually checked on macOS.
- Create a stable Developer ID signing identity and protected CI secrets.
- Keep managed resources outside executable-code locations where practical and
  sign every Mach-O executable and `.dylib` before signing the outer app bundle.
- Enable hardened runtime with only the entitlements proven necessary.
- Submit the ZIP or DMG with `xcrun notarytool`, require an Accepted result,
  inspect the complete log, and staple the ticket before packaging.
- Download the artifact through a browser so quarantine is present, then verify
  Gatekeeper on a clean user account.

Phase 3 exit: `codesign --verify --deep --strict`, `spctl`, notarization, stapling,
and quarantined first launch all pass on a clean Mac.

## Phase 4 — release integration

- Add macOS artifacts, hashes, build metadata, and architecture evidence to a
  platform-specific release manifest.
- Extend GitHub release publication without weakening the current Windows
  manifest/build-ID checks.
- Add a macOS installation guide covering Applications-folder installation,
  upgrades, settings preservation, Gatekeeper, and uninstall.
- Ensure update notices direct Mac users to a Mac asset rather than a Windows
  installer.

Phase 4 exit: a tagged commit produces independently verified Windows and macOS
assets, and the release page makes the platform choice unambiguous.

## Separate decision — native system screensaver

The Windows `.scr` and preview-parent Win32 APIs cannot be reused as macOS system
screensaver integration. A real Mac screensaver requires a `.saver` bundle and a
Cocoa `ScreenSaverView` host with the same architecture as the screen-saver
engine. Treat that as a separate project after the normal application is stable.

Before implementing it, compare:

1. a documented fullscreen/launch-at-login mode using the existing app;
2. a small Swift or Objective-C `.saver` host sharing rendered frames or core
   playback logic;
3. maintaining only the normal Mac app if modern macOS compatibility, signing,
   or maintenance cost makes a plug-in disproportionate.

Do not advertise native screensaver support until installation, configuration,
preview, multi-display behavior, architecture compatibility, signing, and
uninstall have all been exercised on supported macOS versions.
