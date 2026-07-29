# HaloPin Installation Guide

HaloPin is distributed directly rather than through the Mac App Store. Follow
these steps only for a copy you intentionally downloaded from the official
HaloPin repository or release page.

## Install HaloPin

1. Open `HaloPin.dmg`.
2. Drag `HaloPin.app` onto the **Applications** shortcut.
3. Wait for the copy to finish, then eject the HaloPin disk image.
4. Open `/Applications` and launch HaloPin.

HaloPin is a menu-bar utility, so it does not normally appear in the Dock.
Look for its pin icon on the right side of the menu bar.

## If macOS blocks the first launch

Public releases should eventually be Developer ID signed and notarized. A
local or development build may instead show a warning that Apple cannot verify
the developer.

Only bypass this warning when you trust the source of the exact file:

1. Try to open HaloPin once, then dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the Security section.
4. Find the message that HaloPin was blocked and click **Open Anyway**.
5. Authenticate with Touch ID or your administrator password if requested.
6. Confirm **Open Anyway** in the final dialog.

You can also Control-click `HaloPin.app` in `/Applications`, choose **Open**,
and confirm the prompt when macOS offers that option.

Do not use **Open Anyway** for an unexpected download or a file from an
untrusted source.

## Grant required permissions

HaloPin requests only the permissions required for its window handoff model.

### Accessibility

Accessibility lets HaloPin identify, position, resize, and raise the original
window.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Enable HaloPin.
3. If HaloPin is missing, click the add button and choose
   `/Applications/HaloPin.app`.

### Screen Recording

Screen Recording lets HaloPin create the local, window-only passive preview.
Captured frames remain in memory and are not saved or transmitted.

1. Open **System Settings → Privacy & Security**.
2. Open **Screen & System Audio Recording** or **Screen Recording**, depending
   on the macOS label shown.
3. Enable HaloPin.

Quit and reopen HaloPin after changing either permission. Use
**HaloPin menu → Permissions… → Refresh Permission Status** to confirm that
both permissions are granted.

## Confirm the installation

1. Focus a normal application window.
2. Press `Control-Option-Command-P`.
3. Switch to another application and confirm the passive HaloPin preview
   appears.
4. Click the preview once to hand off to the original interactive window.
5. Press the shortcut again to unpin.

## Permission troubleshooting

- Install and run HaloPin from `/Applications`; do not keep launching it from
  the disk image.
- If a permission remains stale, remove HaloPin from that permission list,
  restart HaloPin, and grant it again.
- Ad-hoc development builds can require fresh grants after recompilation.
  Stable Developer ID signatures are required for production-grade permission
  persistence across updates.
- Protected or DRM content is intentionally unsupported.

For additional help, see `TROUBLESHOOTING.md`, `PERMISSIONS.md`, and
`KNOWN_LIMITATIONS.md` in the **Installation Guide and Docs** folder.
