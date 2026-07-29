# Troubleshooting

## The shortcut does nothing

Check both permissions from the HaloPin menu. Record a different shortcut if
macOS or another application owns the current combination. HaloPin validates a
new shortcut before replacing the working one.

## The preview says Paused

The source stopped producing usable frames. During a Space transition, HaloPin
checks whether the exact source window is available on the active Desktop. If
it is off-Space, follow the preview guide: right-click the source application
in the Dock and choose **Options → Assign To → All Desktops**, then select
**I’ve Assigned It**. This setting affects the entire application.

Choose **Not Now** to keep the last frame visibly marked
**Off Desktop — Paused**. Clicking that preview still activates the real
window and may switch to its original Space.

## The preview is black

Confirm Screen Recording permission and reopen HaloPin after changing it.
Protected video and DRM content are deliberately rejected and are never
bypassed.

## The real window appears at a different size

The source application enforced a minimum, maximum, aspect-ratio, or placement
constraint. HaloPin reads the accepted frame back and uses it.

## The app is not in the Dock

This is intentional. HaloPin is an accessory app controlled from its menu-bar
pin icon.

## Permissions disappeared after an update

Install to `/Applications` and verify the release retained the same bundle
identifier and Developer ID signature. Ad-hoc development builds do not provide
stable production TCC identity.

## Gatekeeper rejects a local development build

The included artifact may be ad-hoc signed for local testing. A public release
must be signed with Developer ID, notarized, and stapled using the supplied
scripts.
