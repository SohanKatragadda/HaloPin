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

    @Published var presentationState: PresentationState = .idle {
        didSet {
            guard case .warning = presentationState else {
                acknowledgeWarning()
                return
            }
        }
    }
    @Published private(set) var warningIndicatorMessage: String?
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
    private let warningIndicatorDuration: Duration
    private var warningIndicatorTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        warningIndicatorDuration: Duration = .seconds(600)
    ) {
        self.defaults = defaults
        self.warningIndicatorDuration = warningIndicatorDuration
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        haloEnabled = defaults.object(forKey: Keys.haloEnabled) as? Bool ?? true
        nativeGeometrySyncEnabled =
            defaults.object(forKey: Keys.nativeGeometrySyncEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    }

    func show(error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showWarning(message)
    }

    func showWarning(_ message: String) {
        presentationState = .warning(message)
        warningIndicatorMessage = message
        warningIndicatorTask?.cancel()
        let duration = warningIndicatorDuration
        warningIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.acknowledgeWarning()
        }
    }

    func acknowledgeWarning() {
        warningIndicatorTask?.cancel()
        warningIndicatorTask = nil
        warningIndicatorMessage = nil
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
