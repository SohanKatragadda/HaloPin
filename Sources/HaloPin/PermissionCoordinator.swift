import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PermissionCoordinator: PermissionCoordinating {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        guard !defaults.bool(forKey: Keys.requestedAccessibility) else {
            openAccessibilitySettings()
            return
        }
        defaults.set(true, forKey: Keys.requestedAccessibility)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecordingPermission() -> Bool {
        guard !defaults.bool(forKey: Keys.requestedScreenRecording) else {
            openScreenRecordingSettings()
            return false
        }
        defaults.set(true, forKey: Keys.requestedScreenRecording)
        return CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    private func openSettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private enum Keys {
        static let requestedAccessibility = "permissions.requestedAccessibility"
        static let requestedScreenRecording = "permissions.requestedScreenRecording"
    }
}
