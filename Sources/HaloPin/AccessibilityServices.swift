import AppKit
import ApplicationServices
import Foundation

enum AccessibilityError: LocalizedError {
    case unavailable(String)
    case operationFailed(AXError)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message
        case let .operationFailed(error):
            "Accessibility operation failed (\(error.rawValue))."
        }
    }
}

@MainActor
final class FocusedWindowResolver: FocusedWindowResolving {
    func resolveFocusedWindow() throws -> ResolvedWindow {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular else {
            throw PinFailure.noFocusedWindow
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window: AXUIElement = AXHelpers.copyAttribute(
            appElement,
            kAXFocusedWindowAttribute as CFString
        ) else {
            throw PinFailure.noFocusedWindow
        }

        let role: String = AXHelpers.copyAttribute(window, kAXRoleAttribute as CFString) ?? ""
        let subrole: String = AXHelpers.copyAttribute(window, kAXSubroleAttribute as CFString) ?? ""
        guard role == (kAXWindowRole as String),
              subrole != (kAXSystemDialogSubrole as String) else {
            throw PinFailure.unsupportedWindow
        }

        let minimized: Bool = AXHelpers.copyAttribute(
            window,
            kAXMinimizedAttribute as CFString
        ) ?? false
        guard !minimized else {
            throw PinFailure.sourceMinimized
        }

        let fullscreen: Bool = AXHelpers.copyAttribute(
            window,
            "AXFullScreen" as CFString
        ) ?? false
        guard !fullscreen else {
            throw PinFailure.sourceFullscreen
        }

        let frame = try AXHelpers.frame(of: window)
        guard frame.width >= 80, frame.height >= 60 else {
            throw PinFailure.unsupportedWindow
        }

        let title: String = AXHelpers.copyAttribute(window, kAXTitleAttribute as CFString) ?? ""
        return ResolvedWindow(
            ownerPID: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? "Application",
            title: title,
            axWindow: window,
            frame: frame
        )
    }
}

@MainActor
final class AccessibilityWindowController: WindowControlling {
    func frame(of window: AXUIElement) throws -> CGRect {
        try AXHelpers.frame(of: window)
    }

    func apply(frame: CGRect, to window: AXUIElement) throws -> CGRect {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let dimensions = AXValueCreate(.cgSize, &size) else {
            throw AccessibilityError.unavailable("Could not encode the requested window frame.")
        }

        let positionResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            position
        )
        let sizeResult = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            dimensions
        )

        guard positionResult == .success || sizeResult == .success else {
            throw AccessibilityError.operationFailed(positionResult)
        }
        return try AXHelpers.frame(of: window)
    }

    func raise(_ window: AXUIElement) throws {
        let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard result == .success else {
            throw AccessibilityError.operationFailed(result)
        }
    }

    func isFrontmost(_ window: AXUIElement, ownerPID: pid_t) -> Bool {
        guard NSRunningApplication(processIdentifier: ownerPID)?.isActive == true else {
            return false
        }
        let appElement = AXUIElementCreateApplication(ownerPID)
        guard let focused: AXUIElement = AXHelpers.copyAttribute(
            appElement,
            kAXFocusedWindowAttribute as CFString
        ) else {
            return false
        }
        return CFEqual(focused, window)
    }

    func isMinimized(_ window: AXUIElement) -> Bool {
        AXHelpers.copyAttribute(window, kAXMinimizedAttribute as CFString) ?? false
    }

    func isFullscreen(_ window: AXUIElement) -> Bool {
        AXHelpers.copyAttribute(window, "AXFullScreen" as CFString) ?? false
    }
}

enum AXHelpers {
    static func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func frame(of window: AXUIElement) throws -> CGRect {
        guard let positionValue: AXValue = copyAttribute(
            window,
            kAXPositionAttribute as CFString
        ), let sizeValue: AXValue = copyAttribute(
            window,
            kAXSizeAttribute as CFString
        ) else {
            throw AccessibilityError.unavailable("The window does not expose a usable frame.")
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            throw AccessibilityError.unavailable("The window frame could not be read.")
        }
        return CGRect(origin: position, size: size)
    }
}
