import AppKit
import Foundation

@MainActor
final class WorkspaceObserver: WorkspaceObserving {
    var onEvent: ((WorkspaceEvent) -> Void)?

    private var workspaceTokens: [NSObjectProtocol] = []
    private var displayToken: NSObjectProtocol?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NSWorkspace.shared.notificationCenter
        observeApplication(
            NSWorkspace.didDeactivateApplicationNotification,
            center: center,
            makeEvent: WorkspaceEvent.ownerDeactivated
        )
        observeApplication(
            NSWorkspace.didActivateApplicationNotification,
            center: center,
            makeEvent: WorkspaceEvent.applicationActivated
        )
        observeApplication(
            NSWorkspace.didTerminateApplicationNotification,
            center: center,
            makeEvent: WorkspaceEvent.applicationTerminated
        )
        observeApplication(
            NSWorkspace.didHideApplicationNotification,
            center: center,
            makeEvent: WorkspaceEvent.applicationHidden
        )

        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onEvent?(.activeSpaceChanged) }
        })

        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ] {
            workspaceTokens.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onEvent?(.suspend) }
            })
        }

        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            workspaceTokens.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onEvent?(.resume) }
            })
        }

        displayToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onEvent?(.screensChanged) }
        }
    }

    private func observeApplication(
        _ name: Notification.Name,
        center: NotificationCenter,
        makeEvent: @escaping @Sendable (pid_t) -> WorkspaceEvent
    ) {
        workspaceTokens.append(center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication)?.processIdentifier
            guard let pid else { return }
            let event = makeEvent(pid)
            Task { @MainActor in self?.onEvent?(event) }
        })
    }
}
