# HaloPin Performance Report

This report compares `main` at `24847dd` with
`agent/performance-tech-debt`. The automated figures below describe configured
workload and lifecycle behavior. End-to-end CPU, latency, and memory numbers
must be recorded on the target Mac with its existing Accessibility and Screen
Recording grants because ScreenCaptureKit behavior and application rendering
cost vary by hardware, display scale, and source application.

## Implemented changes

| Scenario | `main` | Optimization branch |
| --- | --- | --- |
| Unpinned | Workspace/display observers and a repeating 500 ms stall timer remain active | No capture stream, watchdog, AX observer, or workspace/display observer |
| Pinned, source interactive | 30 fps, native resolution, queue depth 3 | 1 fps, longest edge capped at 1280 px, queue depth 1 |
| Passive preview visible | 30 fps, native resolution, queue depth 3 | 30 fps, native resolution, queue depth 2 |
| Off-Space paused, sleep, inactive login session | Stream may remain running during recovery/fallback | Stream stops while the last displayed frame remains |
| Fresh-frame waits | 8 ms polling loop | Complete-frame continuation with timeout and cancellation |
| Frame callbacks | A main-actor task can be created for every sample heartbeat | UI callback only when health changes |
| Cleanup | Capture operations live in the session controller | Generation-aware lifecycle coordinator serializes profile changes and stop/start |

The warm profile reduces the configured interactive frame rate by 96.7%
(30 fps to 1 fps) before accounting for its resolution cap. Its maximum queued
frame count is 66.7% lower (3 to 1). Visible passive capture keeps the original
30 fps and native output dimensions.

## Technical-debt reduction

- Capture profiles, stream generations, health monitoring, and serialized
  cleanup now live behind `CaptureLifecycleManaging`.
- Stream callbacks validate immutable stream identity through a lock-protected
  generation tracker; superseded streams cannot render or report failure.
- One transition function validates all product-state changes.
- Timing used by capture, recovery, identity refresh, geometry, watchdog, and
  handoff is centralized in injectable `SessionTiming`.
- Preview health properties suppress duplicate layer updates.
- Workspace observers are installed after a pin succeeds and removed on every
  cleanup path.
- The unused preview aspect-ratio field, AX title notification, and recovery
  flag were removed.
- Privacy-redacted signposts cover pin establishment, passive entry, capture
  rebind, first fresh frame, and native handoff.

## Automated verification

The Swift suite contains 43 tests on this branch (34 retained and 9 added).
New coverage includes warm/live calculations and transitions, preserved-frame
stops, observer scoping, health transition coalescing, continuation success and
timeout, stale stream replacement, serialized stop/start, and the complete
state-transition table. All 43 pass in both debug and release configurations.

The packaged executable was also verified as a universal `x86_64`/`arm64`
Mach-O, its Hardened Runtime signature passed strict validation, the source ZIP
passed an archive integrity test, and `hdiutil verify` accepted the DMG. The
current build is ad-hoc signed because no Apple Development or Developer ID
identity is installed on the build Mac.

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --disable-sandbox
```

## Manual profiling protocol

Use the same source application, window geometry, display arrangement, and
five-minute sampling interval for `main` and the optimization branch. Record
Activity Monitor or Instruments CPU and memory after the first 30 seconds:

| Scenario | Main CPU | Branch CPU | Main memory | Branch memory | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Unpinned idle | — | — | — | — | Pending target-Mac measurement |
| Pinned, interactive/hidden preview | — | — | — | — | Target: at least 70% lower CPU |
| Passive static 1080p | — | — | — | — | Target: under 150 MB |
| Passive animated 1080p | — | — | — | — | Target: 30 fps, under 150 MB |
| Repeated handoff/resize/Space changes | — | — | — | — | Check latency, flicker, and stalls |

Also verify passive entry within 200 ms, cross-Space recovery within 500 ms,
and continuously advancing Apple Music lyrics after moving across Desktops.
These visual and timing checks are intentionally not inferred from unit tests.
