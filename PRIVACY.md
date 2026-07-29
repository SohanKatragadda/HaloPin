# HaloPin Privacy Statement

HaloPin processes the selected window locally and in memory.

- ScreenCaptureKit is filtered to the single window the user pins.
- Captured frames are rendered directly and are never encoded or written to
  application storage.
- Audio is never captured.
- Window titles, contents, coordinates, and application activity are not
  persisted.
- HaloPin has no analytics, advertising, updater, telemetry, or network code.
- Logs redact error details and do not log window titles or coordinates.
- HaloPin requests only Accessibility and Screen Recording privacy access.
- HaloPin does not require root access, a privileged helper, or reduced SIP.

Unpinning or quitting stops the stream and discards the in-memory frame.
