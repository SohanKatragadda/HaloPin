import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private weak var sessions: PinSessionController?
    private let showSettings: () -> Void
    private var cancellables: Set<AnyCancellable> = []

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

        model.$warningIndicatorMessage
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

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
        model.acknowledgeWarning()
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
        if model.warningIndicatorMessage != nil {
            symbolName = "exclamationmark.triangle.fill"
        } else {
            symbolName = standardSymbolName
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "HaloPin"
        )
        statusItem.button?.toolTip = "HaloPin"
    }

    private var standardSymbolName: String {
        switch model.presentationState {
        case .idle:
            return "pin"
        case .resolving:
            return "ellipsis.circle"
        case .interactive:
            return "pin.fill"
        case .passive:
            return "pin.circle.fill"
        case .warning:
            switch sessions?.session?.state {
            case .resolving:
                return "ellipsis.circle"
            case .interactive:
                return "pin.fill"
            case .becomingPassive, .passive, .handingOff:
                return "pin.circle.fill"
            default:
                return "pin"
            }
        }
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
