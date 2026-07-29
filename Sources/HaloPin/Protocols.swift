import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
protocol PermissionCoordinating: AnyObject {
    var hasAccessibilityPermission: Bool { get }
    var hasScreenRecordingPermission: Bool { get }
    func requestAccessibilityPermission()
    func requestScreenRecordingPermission() -> Bool
    func openAccessibilitySettings()
    func openScreenRecordingSettings()
}

@MainActor
protocol GlobalShortcutManaging: AnyObject {
    var shortcut: ShortcutDefinition { get }
    var onPressed: (() -> Void)? { get set }
    func update(_ proposed: ShortcutDefinition, defaults: UserDefaults) throws
}

@MainActor
protocol FocusedWindowResolving: AnyObject {
    func resolveFocusedWindow() throws -> ResolvedWindow
}

@MainActor
protocol WindowIdentityMapping: AnyObject {
    func map(_ window: ResolvedWindow) async throws -> CaptureWindowReference
    func refresh(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) async throws -> CaptureWindowReference
}

@MainActor
protocol WindowControlling: AnyObject {
    func frame(of window: AXUIElement) throws -> CGRect
    func apply(frame: CGRect, to window: AXUIElement) throws -> CGRect
    func raise(_ window: AXUIElement) throws
    func isFrontmost(_ window: AXUIElement, ownerPID: pid_t) -> Bool
    func isMinimized(_ window: AXUIElement) -> Bool
    func isFullscreen(_ window: AXUIElement) -> Bool
}

@MainActor
protocol CaptureStreaming: AnyObject {
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var onHealthChanged: ((CaptureHealth) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start(
        window: CaptureWindowReference,
        profile: CaptureProfile
    ) async throws
    func refresh(
        window: CaptureWindowReference,
        frame: CGRect,
        profile: CaptureProfile
    ) async throws
    func update(frame: CGRect, profile: CaptureProfile) async throws
    func awaitCompleteFrameAdvance(count: UInt64, timeout: Duration) async -> Bool
    func validateInitialFrame(timeout: Duration) async throws
    func setHealthMonitoring(enabled: Bool, stallTimeout: Duration)
    func stop(preserveDisplayedFrame: Bool) async
}

@MainActor
protocol CaptureLifecycleManaging: AnyObject {
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var mode: CaptureLifecycleMode { get }
    var onHealthChanged: ((CaptureHealth) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func prepare(window: CaptureWindowReference) async throws
    func enterWarm(frame: CGRect) async
    func enterLive(
        window: CaptureWindowReference,
        frame: CGRect
    ) async throws
    func updateGeometry(_ frame: CGRect) async throws
    func awaitCompleteFrameAdvance(count: UInt64, timeout: Duration) async -> Bool
    func pausePreservingFrame() async
    func suspend() async
    func requestStop()
    func waitUntilStopped() async
}

@MainActor
protocol PreviewPresenting: AnyObject {
    var previewFrame: CGRect? { get }
    var onActivate: (() -> Void)? { get set }
    var onFrameChanged: ((CGRect) -> Void)? { get set }
    var onGeometryCommitted: ((PreviewGeometryCommit) -> Void)? { get set }
    var onAllDesktopsConfirmed: (() -> Void)? { get set }
    var onAllDesktopsDeclined: (() -> Void)? { get set }
    func configure(displayLayer: CALayer, frame: CGRect, aspectRatio: CGSize)
    func show()
    func hide()
    func freeze()
    func setPaused(_ paused: Bool)
    func setCrossSpaceState(
        _ state: CrossSpaceCaptureState,
        applicationName: String
    )
    func updateSourceGeometry(_ frame: CGRect)
    func animate(to frame: CGRect)
    func fadeOut(completion: @escaping @MainActor @Sendable () -> Void)
    func clampToVisibleScreens()
    func tearDown()
}

@MainActor
protocol FeedbackPresenting: AnyObject {
    func presentPinFeedback(around axFrame: CGRect, halo: Bool, sound: Bool)
    func presentUnpinFeedback(sound: Bool)
    func showHUD(_ message: String)
}

enum WorkspaceEvent: Sendable {
    case ownerDeactivated(pid_t)
    case applicationActivated(pid_t)
    case applicationTerminated(pid_t)
    case applicationHidden(pid_t)
    case activeSpaceChanged
    case screensChanged
    case suspend
    case resume
}

@MainActor
protocol WorkspaceObserving: AnyObject {
    var onEvent: ((WorkspaceEvent) -> Void)? { get set }
    func start()
    func stop()
}
