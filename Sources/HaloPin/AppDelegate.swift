import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private let permissions = PermissionCoordinator()
    private let shortcuts = GlobalShortcutManager()
    private lazy var sessions = PinSessionController(
        model: model,
        permissions: permissions
    )
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = StatusItemController(
            model: model,
            sessions: sessions
        ) { [weak self] in
            self?.showSettings()
        }
        sessions.onMenuNeedsUpdate = { [weak self] in
            self?.statusItem?.refresh()
        }
        shortcuts.onPressed = { [weak self] in
            self?.sessions.togglePin()
        }

        if !permissions.hasAccessibilityPermission || !permissions.hasScreenRecordingPermission {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessions.unpin()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        sessions.refreshPermissions()
    }

    func showSettings() {
        if let settingsWindow {
            settingsWindow.showWindow(nil)
            settingsWindow.window?.center()
            NSApp.activate()
            return
        }

        let view = SettingsView(
            model: model,
            permissions: permissions,
            shortcuts: shortcuts,
            sessions: sessions
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "HaloPin Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindow = controller
        controller.showWindow(nil)
        NSApp.activate()
    }
}
