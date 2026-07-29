import AppKit
import Carbon
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let permissions: PermissionCoordinator
    let shortcuts: GlobalShortcutManager
    let sessions: PinSessionController

    @State private var shortcut: ShortcutDefinition
    @State private var loginError: String?

    init(
        model: AppModel,
        permissions: PermissionCoordinator,
        shortcuts: GlobalShortcutManager,
        sessions: PinSessionController
    ) {
        self.model = model
        self.permissions = permissions
        self.shortcuts = shortcuts
        self.sessions = sessions
        _shortcut = State(initialValue: shortcuts.shortcut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            permissionsSection
            Divider()
            behaviorSection
            Divider()
            privacySection
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "pin.circle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("HaloPin")
                    .font(.title2.bold())
                Text("A live preview that hands off to the original window.")
                    .foregroundStyle(.secondary)
                Text("The first preview click activates only; your next click is fully native.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)
            PermissionRow(
                title: "Accessibility",
                detail: "Finds, positions, and raises the original window.",
                granted: permissions.hasAccessibilityPermission,
                grant: {
                    permissions.requestAccessibilityPermission()
                    model.permissionsRevision += 1
                },
                openSettings: permissions.openAccessibilitySettings
            )
            PermissionRow(
                title: "Screen Recording",
                detail: "Captures only the window you explicitly pin.",
                granted: permissions.hasScreenRecordingPermission,
                grant: {
                    _ = permissions.requestScreenRecordingPermission()
                    model.permissionsRevision += 1
                },
                openSettings: permissions.openScreenRecordingSettings
            )
            Button("Refresh Permission Status") {
                sessions.refreshPermissions()
            }
            .controlSize(.small)
        }
        .id(model.permissionsRevision)
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Behavior")
                .font(.headline)

            HStack {
                Text("Global shortcut")
                Spacer()
                ShortcutRecorder(
                    shortcut: $shortcut,
                    onChange: updateShortcut
                )
                .frame(width: 150, height: 28)
            }

            if let shortcutError = model.shortcutError {
                Text(shortcutError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("Play pin and unpin sounds", isOn: $model.soundEnabled)
            Toggle("Show pin halo", isOn: $model.haloEnabled)
            Toggle(
                "Resize and move original window when adjusting preview",
                isOn: $model.nativeGeometrySyncEnabled
            )
            Toggle("Launch at login", isOn: launchAtLoginBinding)

            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Local and memory-only", systemImage: "hand.raised.fill")
                .font(.headline)
            Text(
                "HaloPin does not save captured frames, record audio, use analytics, "
                    + "or make network requests. SIP stays fully enabled."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    model.launchAtLogin = enabled
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                    model.launchAtLogin = false
                }
            }
        )
    }

    private func updateShortcut(_ proposed: ShortcutDefinition) {
        do {
            try shortcuts.update(proposed)
            shortcut = proposed
            model.shortcutError = nil
        } catch {
            shortcut = shortcuts.shortcut
            model.shortcutError = error.localizedDescription
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant", action: grant)
                Button("Settings", action: openSettings)
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: ShortcutDefinition
    let onChange: (ShortcutDefinition) -> Void

    func makeNSView(context: Context) -> ShortcutTextField {
        let field = ShortcutTextField()
        field.onShortcut = onChange
        field.shortcut = shortcut
        return field
    }

    func updateNSView(_ nsView: ShortcutTextField, context: Context) {
        nsView.shortcut = shortcut
        nsView.onShortcut = onChange
    }
}

private final class ShortcutTextField: NSTextField {
    var onShortcut: ((ShortcutDefinition) -> Void)?
    var shortcut: ShortcutDefinition = .defaultShortcut {
        didSet { stringValue = shortcut.displayString }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        focusRingType = .exterior
        toolTip = "Click, then press a shortcut"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "Press shortcut…"
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            stringValue = shortcut.displayString
            window?.makeFirstResponder(nil)
            return
        }
        let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        let proposed = ShortcutDefinition(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers
        )
        guard proposed.isValid else {
            NSSound.beep()
            return
        }
        onShortcut?(proposed)
        window?.makeFirstResponder(nil)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
