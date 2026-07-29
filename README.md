# HaloPin

HaloPin is a menu-bar-only macOS 26 utility that keeps one selected window
visually available without modifying another process or weakening System
Integrity Protection.

It uses a deliberate two-mode design:

1. While the source application is active, you interact with its real window.
2. When that application deactivates, HaloPin shows a live, floating,
   window-only ScreenCaptureKit preview.
   When Spaces change, HaloPin verifies that the exact source window remains
   available. If macOS stops rendering it off-Space, HaloPin labels the
   preserved frame Paused and can guide you to assign the source application
   to All Desktops.
3. Clicking the preview consumes that click, moves the original window to the
   preview frame, activates and raises it, verifies the exact AX window, and
   removes the preview. The next click and all keyboard, pointer, menu,
   drag-and-drop, and accessibility interaction are native.

There is no input forwarding, synthetic replay, private WindowServer API,
process injection, virtual display, persistent capture, or network access.

## Requirements

- macOS 26 or newer
- Apple silicon or 64-bit Intel Mac
- Accessibility permission
- Screen Recording permission
- SIP may and should remain fully enabled

## Use

1. Move `HaloPin.app` to `/Applications` and open it.
2. Grant Accessibility and Screen Recording in System Settings.
3. Focus an eligible window and press `Control-Option-Command-P`.
4. Switch to another application. The passive preview appears.
5. Click the captured content once to activate the real source window.
6. Press the shortcut again anywhere to unpin. Intentional unpinning plays a
   distinct confirmation cue when sounds are enabled.

Drag with the small handle at the top of the preview. Resize from its edges.
By default, releasing either gesture applies the complete preview frame to the
inactive source window so the application renders natively at that size. Turn
off “Resize and move original window when adjusting preview” to retain a purely
scaled preview until handoff. The shortcut, sound, halo, native geometry sync,
and Launch at Login behavior are configurable from the menu-bar menu.

If an off-Space application stops rendering, follow the preview’s instructions
to right-click that application in the Dock and choose
**Options → Assign To → All Desktops**. This is an application-wide macOS
setting. Choose **Not Now** to retain a clearly marked paused preview and
click-to-handoff behavior for the current pin session.

## Build and test

The package uses Swift 6.2, AppKit, SwiftUI, Accessibility, Carbon hot keys,
ScreenCaptureKit, AVFoundation, and ServiceManagement. It has no third-party
dependencies.

Capture work is profile-driven: hidden interactive windows use a capped 1 fps
warm stream, visible passive previews use native-resolution 30 fps capture,
and off-Space or suspended sessions stop the stream while retaining the last
displayed image. See [PERFORMANCE.md](PERFORMANCE.md) for the implementation
report and profiling procedure.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --disable-sandbox

./Scripts/build-app.sh
```

`build-app.sh` creates a universal, Hardened Runtime app at
`outputs/HaloPin.app`. It automatically uses an installed Apple Development or
Developer ID Application identity. Set `SIGN_IDENTITY` and
`PRODUCT_BUNDLE_IDENTIFIER` for a Developer ID build:

```sh
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
PRODUCT_BUNDLE_IDENTIFIER="com.example.HaloPin" \
./Scripts/build-app.sh
```

If no signing identity is installed, the script creates an ad-hoc development
build and prints a warning. Permissions persist across ordinary quit/relaunch
of that exact build, but macOS treats every newly compiled ad-hoc binary as a
different privacy requester. Install an Apple Development certificate for
stable permissions during development; public releases require Developer ID.

Run the integration fixture from Xcode or with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run --disable-sandbox HaloPinFixture
```

The fixture provides resizable, fixed-size, duplicate-title, AppKit, SwiftUI,
WebKit, modal, and sheet cases.

## Release

After a Developer ID build:

```sh
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
./Scripts/package-dmg.sh

NOTARY_PROFILE="halopin-notary" ./Scripts/notarize.sh
```

The notary profile is created with `xcrun notarytool store-credentials`.
The notarization script submits the DMG, waits, staples it and the app, and
validates both.

## Source layout

- `Sources/HaloPin`: application and protocol-backed services
- `Sources/HaloPinFixture`: signed integration host fixture
- `Tests/HaloPinTests`: state, identity, geometry, and shortcut tests
- `Configuration`: bundle metadata, entitlements, and release settings
- `Scripts`: universal build, DMG packaging, and notarization

See [PRIVACY.md](PRIVACY.md), [PERMISSIONS.md](PERMISSIONS.md),
[PERFORMANCE.md](PERFORMANCE.md), [TROUBLESHOOTING.md](TROUBLESHOOTING.md), and
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).
