import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private weak var sessions: PinSessionController?
    private let showSettings: () -> Void

    init(
        model: AppModel,
        sessions: PinSessionController,
        showSettings: @escaping () -> Void
    ) {
        self.model = model
        self.sessions = sessions
        self.showSettings = showSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        rebuildMenu(menu)
    }

    func refresh() {
        refreshIcon()
        if let menu = statusItem.menu {
            rebuildMenu(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
        refreshIcon()
    }

    @objc private func togglePin() {
        sessions?.togglePin()
    }

    @objc private func showPinnedWindow() {
        sessions?.showPinnedWindow()
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshIcon() {
        let symbolName: String
        switch model.presentationState {
        case .idle:
            symbolName = "pin"
        case .resolving:
            symbolName = "ellipsis.circle"
        case .interactive:
            symbolName = "pin.fill"
        case .passive:
            symbolName = "pin.circle.fill"
        case .warning:
            symbolName = "exclamationmark.triangle.fill"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "HaloPin"
        )
        statusItem.button?.toolTip = "HaloPin"
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let isPinned = sessions?.session != nil
        let toggleTitle = isPinned
            ? "Unpin \(model.pinnedWindowName ?? "Window")"
            : "Pin Focused Window"
        let toggle = NSMenuItem(
            title: toggleTitle,
            action: #selector(togglePin),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if isPinned {
            let show = NSMenuItem(
                title: "Show Pinned Window",
                action: #selector(showPinnedWindow),
                keyEquivalent: ""
            )
            show.target = self
            menu.addItem(show)
        }

        if case let .warning(message) = model.presentationState {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let permissions = NSMenuItem(
            title: "Permissions…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        permissions.target = self
        menu.addItem(permissions)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit HaloPin",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }
}
