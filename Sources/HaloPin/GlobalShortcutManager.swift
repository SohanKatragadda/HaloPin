import Carbon
import Foundation

struct ShortcutDefinition: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = ShortcutDefinition(
        keyCode: 35,
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    var displayString: String {
        var output = ""
        if modifiers & UInt32(controlKey) != 0 { output += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }
        output += KeyCodeNames.name(for: keyCode)
        return output
    }

    var isValid: Bool {
        keyCode <= UInt32(UInt16.max)
            && modifiers != 0
            && !isReservedSystemCombination
    }

    private var isReservedSystemCombination: Bool {
        let command = UInt32(cmdKey)
        let control = UInt32(controlKey)
        let shift = UInt32(shiftKey)
        let exactModifiers = modifiers & UInt32(cmdKey | controlKey | optionKey | shiftKey)

        if exactModifiers == command, [48, 49].contains(keyCode) {
            return true // Command-Tab and Command-Space.
        }
        if exactModifiers == command | shift, [20, 21, 23].contains(keyCode) {
            return true // Common system screenshot shortcuts.
        }
        if exactModifiers == control, [123, 124, 125, 126].contains(keyCode) {
            return true // Mission Control and Spaces navigation.
        }
        return false
    }
}

enum ShortcutRegistrationError: LocalizedError {
    case invalid
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalid:
            "Choose a key together with at least one modifier."
        case .unavailable:
            "That shortcut is reserved or already in use."
        }
    }
}

@MainActor
final class GlobalShortcutManager: GlobalShortcutManaging {
    private static let signature: OSType = 0x484C504E // HLPN
    private static let identifier: UInt32 = 1
    private static let defaultsKey = "shortcut.definition"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private(set) var shortcut: ShortcutDefinition
    var onPressed: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(ShortcutDefinition.self, from: data) {
            shortcut = decoded
        } else {
            shortcut = .defaultShortcut
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            haloPinHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if (try? register(shortcut)) == nil {
            shortcut = .defaultShortcut
            try? register(shortcut)
        }
    }

    func update(_ proposed: ShortcutDefinition, defaults: UserDefaults = .standard) throws {
        guard proposed.isValid else {
            throw ShortcutRegistrationError.invalid
        }

        let previous = shortcut
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        do {
            try register(proposed)
            shortcut = proposed
            let data = try JSONEncoder().encode(proposed)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            try? register(previous)
            throw error
        }
    }

    fileprivate func handleRegisteredHotKey() {
        onPressed?()
    }

    private func register(_ shortcut: ShortcutDefinition) throws {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw ShortcutRegistrationError.unavailable
        }
        hotKeyRef = reference
    }
}

private func haloPinHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr,
          identifier.signature == 0x484C504E,
          identifier.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleRegisteredHotKey()
    }
    return noErr
}

private enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 51: "Delete", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}
