import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum PresentationState: Equatable {
        case idle
        case resolving
        case interactive
        case passive
        case warning(String)
    }

    @Published var presentationState: PresentationState = .idle
    @Published var pinnedWindowName: String?
    @Published var shortcutError: String?
    @Published var permissionsRevision = 0

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    @Published var haloEnabled: Bool {
        didSet { defaults.set(haloEnabled, forKey: Keys.haloEnabled) }
    }

    @Published var nativeGeometrySyncEnabled: Bool {
        didSet {
            defaults.set(
                nativeGeometrySyncEnabled,
                forKey: Keys.nativeGeometrySyncEnabled
            )
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        haloEnabled = defaults.object(forKey: Keys.haloEnabled) as? Bool ?? true
        nativeGeometrySyncEnabled =
            defaults.object(forKey: Keys.nativeGeometrySyncEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    }

    func show(error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        presentationState = .warning(message)
    }

    func clearSession() {
        pinnedWindowName = nil
        presentationState = .idle
    }

    private enum Keys {
        static let soundEnabled = "feedback.soundEnabled"
        static let haloEnabled = "feedback.haloEnabled"
        static let nativeGeometrySyncEnabled = "preview.nativeGeometrySyncEnabled"
        static let launchAtLogin = "application.launchAtLogin"
    }
}
