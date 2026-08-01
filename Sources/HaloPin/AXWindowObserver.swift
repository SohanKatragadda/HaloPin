import ApplicationServices
import Foundation

final class AXWindowObserver: @unchecked Sendable {
    enum Event {
        case destroyed
        case movedOrResized
        case minimized
        case focusedWindowChanged
    }

    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    private let onEvent: @MainActor (Event) -> Void

    init(
        pid: pid_t,
        window: AXUIElement,
        onEvent: @escaping @MainActor (Event) -> Void
    ) throws {
        self.onEvent = onEvent

        var createdObserver: AXObserver?
        let result = AXObserverCreate(pid, haloPinAXObserverCallback, &createdObserver)
        guard result == .success, let createdObserver else {
            throw AccessibilityError.operationFailed(result)
        }
        observer = createdObserver

        let notifications: [CFString] = [
            kAXUIElementDestroyedNotification as CFString,
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString
        ]

        for notification in notifications {
            AXObserverAddNotification(
                createdObserver,
                window,
                notification,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        let application = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(
            createdObserver,
            application,
            kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )

        let source = AXObserverGetRunLoopSource(createdObserver)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    fileprivate func receive(notification: CFString) {
        let event: Event?
        switch notification as String {
        case kAXUIElementDestroyedNotification:
            event = .destroyed
        case kAXMovedNotification, kAXResizedNotification:
            event = .movedOrResized
        case kAXWindowMiniaturizedNotification:
            event = .minimized
        case kAXFocusedWindowChangedNotification:
            event = .focusedWindowChanged
        default:
            event = nil
        }
        guard let event else { return }
        Task { @MainActor [onEvent] in
            onEvent(event)
        }
    }
}

private func haloPinAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let userData else { return }
    let owner = Unmanaged<AXWindowObserver>.fromOpaque(userData).takeUnretainedValue()
    owner.receive(notification: notification)
}
