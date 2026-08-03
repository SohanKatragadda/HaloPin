# HaloPin v0.1 Installation Guide

Only install HaloPin from an official HaloPin release page or repository.

## Install HaloPin

1. Open `HaloPin-v0.1.dmg`.
2. Drag `HaloPin.app` to the **Applications** folder shortcut.
3. Wait for the copy to finish, then eject the HaloPin disk image.
4. Open `/Applications` and launch HaloPin.

HaloPin runs from the menu bar. Look for its pin icon at the right side of the
menu bar.

## If macOS blocks the first launch

Only continue if you trust the exact download.

1. Try opening HaloPin once and dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Find the security message for HaloPin and choose **Open Anyway**.
4. Authenticate if macOS asks, then confirm **Open Anyway**.

You can also Control-click `HaloPin.app` in Applications, select **Open**, and
confirm the prompt.

## Grant permissions

HaloPin requests two permissions. It needs both before it can pin a window.

### Accessibility

Accessibility lets HaloPin find, position, resize, and raise the original
window.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Turn on HaloPin.
3. If HaloPin is missing, use the add button and choose
   `/Applications/HaloPin.app`.

### Screen Recording

Screen Recording lets HaloPin show the selected window in its local floating
preview. It does not record audio or save captured frames.

1. Open **System Settings → Privacy & Security**.
2. Open **Screen & System Audio Recording** or **Screen Recording**.
3. Turn on HaloPin.

Quit and reopen HaloPin after changing either permission. Use
**HaloPin menu → Permissions… → Refresh Permission Status** to confirm both
permissions are granted.

## Confirm it works

1. Focus a normal application window.
2. Press `Control-Option-Command-P`.
3. Switch to another application and check that the HaloPin preview appears.
4. Click the preview once to activate the original window.
5. Press the shortcut again to unpin.

## Troubleshooting

- Run HaloPin from `/Applications`, not from the disk image.
- If a permission does not update, remove HaloPin from that privacy list,
  restart HaloPin, and grant it again.
- Protected video and DRM content cannot be pinned.
- Some applications may not keep rendering their windows across separate
  Desktops. HaloPin will clearly mark the preview as paused; clicking it can
  still return to the original window.
