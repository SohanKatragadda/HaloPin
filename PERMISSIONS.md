# Permission Guide

HaloPin needs two macOS privacy permissions.

## Accessibility

Used to identify the focused window, read and request its frame, perform
`AXRaise`, observe close/minimize/move/resize events, and verify that the exact
window is frontmost. HaloPin does not synthesize or forward clicks or keys.

Open: **System Settings → Privacy & Security → Accessibility**.

## Screen Recording

Used by ScreenCaptureKit to produce the window-only passive preview. Audio and
the rest of the display are excluded from the stream.

Open: **System Settings → Privacy & Security → Screen & System Audio
Recording**.

## Granting and revoking

HaloPin asks only when pinning is first attempted or when Grant is selected.
After denial, it routes to System Settings instead of repeatedly prompting.
Some permission changes require quitting and reopening the app.

If either permission is revoked during a pin session, HaloPin stops the session
and removes the overlay. Keep the app in `/Applications` and preserve its
bundle identifier and Developer ID signature across upgrades so macOS can
associate existing grants with the new version.
