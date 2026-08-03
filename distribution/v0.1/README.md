# HaloPin v0.1

HaloPin keeps one selected Mac window visually available while you work in
other applications. When you click its floating preview, HaloPin brings the
original window forward so all further interaction remains fully native.

## Before you install

- Requires macOS 26 or later on Apple silicon or a 64-bit Intel Mac.
- HaloPin needs Accessibility and Screen Recording permission. These are used
  only to position the selected window and show its local live preview.
- HaloPin is a menu-bar utility, so it does not normally appear in the Dock.

## Install

1. Download `HaloPin-v0.1.dmg` from the official HaloPin release page.
2. Open the disk image and drag HaloPin to Applications.
3. Eject the disk image, then open HaloPin from Applications.
4. Follow [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) to grant permissions.

## Use

1. Focus a normal application window.
2. Press `Control-Option-Command-P` to pin it.
3. Switch to another application to show the floating preview.
4. Click the preview once to return to the original interactive window.
5. Press the shortcut again to unpin.

The shortcut, sounds, halo, native resize behavior, and Launch at Login option
can be changed from the HaloPin menu-bar menu.

## Privacy

HaloPin captures only the window you choose. It does not capture audio, save
frames, send data over the network, or use analytics.

## Important limitation

The first click on the floating preview activates the original window only. It
is not replayed to a control under the pointer. Your next click and all
subsequent interaction happen directly in the original application.
