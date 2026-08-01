# Known Limitations

- HaloPin supports one window at a time.
- The first click on passive preview content only activates the source. It is
  intentionally not replayed.
- Cross-Space and fullscreen-auxiliary preview placement is best effort.
  HaloPin cannot publicly move another application’s window between Spaces.
  Applications that stop rendering while off-Space show a preserved frame
  labeled Paused. Assigning the source application to All Desktops can keep it
  live, but that macOS setting affects every window in the application.
  Activating the source can switch to its original Space.
- A source application may reject or clamp requested size and position. HaloPin
  accepts the native result and aligns the preview to it.
- During a passive move or resize gesture, the current captured frame is scaled
  temporarily. Native source geometry and fresh capture resolution are applied
  after the pointer is released.
- Minimized, hidden, native-fullscreen, modal-only, protected/DRM, system,
  screen-saver, login, and exclusive-fullscreen-game windows are unsupported.
- Some applications expose incomplete Accessibility metadata or notifications.
- A stalled capture is marked Paused. Clicking it still attempts native
  handoff.
- Window pins are not restored after either application restarts.
- HaloPin is not equivalent to Calculator’s internal “Keep on Top” command.
  Calculator owns its window and can set its native window level. Public macOS
  APIs do not let HaloPin change another process’s window level, so HaloPin
  uses preview-to-original handoff.
