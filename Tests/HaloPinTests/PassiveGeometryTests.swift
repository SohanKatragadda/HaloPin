import ApplicationServices
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import HaloPin

@MainActor
final class PassiveGeometryTests: XCTestCase {
    func testNativeGeometrySettingDefaultsOnAndPersists() {
        let defaults = makeDefaults()
        let first = AppModel(defaults: defaults)
        XCTAssertTrue(first.nativeGeometrySyncEnabled)

        first.nativeGeometrySyncEnabled = false
        let second = AppModel(defaults: defaults)
        XCTAssertFalse(second.nativeGeometrySyncEnabled)
    }

    func testIdleControllerHasNoWorkspaceObserversOrCapture() {
        let harness = makeHarness(installSession: false)

        XCTAssertEqual(harness.workspace.startCount, 0)
        XCTAssertEqual(harness.workspace.stopCount, 0)
        XCTAssertTrue(harness.capture.profiles.isEmpty)
        XCTAssertTrue(harness.capture.healthMonitoringValues.isEmpty)
    }

    func testSuccessfulPinValidatesLiveThenWarmsAndScopesObservers() async {
        let harness = makeHarness(installSession: false)
        let axWindow = AXUIElementCreateApplication(
            ProcessInfo.processInfo.processIdentifier
        )
        harness.resolver.result = ResolvedWindow(
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: "com.halopin.tests",
            applicationName: "Fixture",
            title: "Window",
            axWindow: axWindow,
            frame: harness.originalFrame
        )
        harness.mapper.mapResult = .testWindow(availability: .available)

        harness.controller.togglePin()
        await waitUntil {
            harness.workspace.startCount == 1
                && harness.capture.profiles.count >= 2
        }

        XCTAssertEqual(Array(harness.capture.profiles.prefix(2)), [.live, .warm])
        XCTAssertEqual(harness.controller.session?.state, .interactive)
        XCTAssertEqual(harness.workspace.stopCount, 0)

        harness.controller.unpin(trigger: .userInitiated)
        await waitUntil {
            harness.capture.stopPreservationValues.last == false
        }

        XCTAssertEqual(harness.workspace.stopCount, 1)
        XCTAssertNil(harness.controller.session)
    }

    func testEnabledCommitAppliesFullFrameAndUsesAcceptedGeometry() async {
        let harness = makeHarness()
        let desired = CGRect(x: 420, y: 180, width: 640, height: 400)
        let accepted = CGRect(x: 420, y: 180, width: 660, height: 420)
        harness.windows.acceptedFrame = accepted
        harness.windows.currentFrame = accepted
        harness.preview.previewFrame = desired

        harness.preview.onGeometryCommitted?(
            PreviewGeometryCommit(kind: .resize, frame: desired)
        )

        await waitUntil { !harness.capture.resizedFrames.isEmpty }

        XCTAssertEqual(harness.windows.appliedFrames, [desired])
        XCTAssertEqual(harness.controller.session?.sourceFrame, accepted)
        XCTAssertEqual(harness.controller.session?.previewFrame, accepted)
        XCTAssertEqual(harness.preview.sourceGeometryUpdates.last, accepted)
        XCTAssertEqual(harness.preview.animatedFrames.last, accepted)
        XCTAssertEqual(harness.capture.resizedFrames, [accepted])
        XCTAssertEqual(harness.capture.frameAdvanceCounts, [2])
        XCTAssertEqual(harness.windows.raiseCount, 0)
    }

    func testDisabledCommitKeepsScaledPreviewBehavior() async {
        let harness = makeHarness()
        harness.model.nativeGeometrySyncEnabled = false
        let desired = CGRect(x: 300, y: 120, width: 540, height: 360)
        harness.preview.previewFrame = desired

        harness.preview.onGeometryCommitted?(
            PreviewGeometryCommit(kind: .move, frame: desired)
        )
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(harness.windows.appliedFrames.isEmpty)
        XCTAssertTrue(harness.capture.resizedFrames.isEmpty)
        XCTAssertEqual(harness.controller.session?.previewFrame, desired)
        XCTAssertEqual(harness.controller.session?.sourceFrame, harness.originalFrame)
    }

    func testAXFailureRetainsPassiveScaledPreview() async {
        let harness = makeHarness()
        harness.windows.applyError = TestFailure.rejected
        let desired = CGRect(x: 210, y: 90, width: 500, height: 320)
        harness.preview.previewFrame = desired

        harness.preview.onGeometryCommitted?(
            PreviewGeometryCommit(kind: .resize, frame: desired)
        )

        await waitUntil { !harness.feedback.messages.isEmpty }

        XCTAssertEqual(harness.controller.session?.state, .passive)
        XCTAssertEqual(harness.controller.session?.sourceFrame, harness.originalFrame)
        XCTAssertEqual(harness.controller.session?.previewFrame, desired)
        XCTAssertTrue(harness.capture.resizedFrames.isEmpty)
        XCTAssertEqual(
            harness.feedback.messages.last,
            "This app could not resize while inactive. Using a scaled preview."
        )
    }

    func testRapidCommitsUseLatestFrame() async {
        let harness = makeHarness()
        let first = CGRect(x: 100, y: 100, width: 600, height: 400)
        let second = CGRect(x: 160, y: 140, width: 720, height: 480)
        harness.preview.previewFrame = first

        harness.preview.onGeometryCommitted?(
            PreviewGeometryCommit(kind: .move, frame: first)
        )
        harness.preview.previewFrame = second
        harness.preview.onGeometryCommitted?(
            PreviewGeometryCommit(kind: .resize, frame: second)
        )

        await waitUntil { harness.capture.resizedFrames.last == second }

        XCTAssertEqual(harness.windows.appliedFrames.last, second)
        XCTAssertEqual(harness.controller.session?.sourceFrame, second)
        XCTAssertEqual(harness.controller.session?.previewFrame, second)
        XCTAssertEqual(harness.capture.resizedFrames.last, second)
    }

    func testRapidSpaceChangesDebounceToLatestRecovery() async {
        let harness = makeHarness()

        harness.workspace.emit(.activeSpaceChanged)
        harness.workspace.emit(.activeSpaceChanged)
        harness.workspace.emit(.activeSpaceChanged)

        await waitUntil { harness.mapper.refreshCallCount == 1 }
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState
                == .offSpaceAwaitingChoice
        }

        XCTAssertEqual(harness.mapper.refreshCallCount, 1)
        XCTAssertEqual(harness.mapper.refreshedWindowIDs, [42])
        XCTAssertEqual(harness.controller.session?.state, .passive)
        XCTAssertEqual(
            harness.preview.crossSpaceStates.last,
            .offSpaceAwaitingChoice
        )
        XCTAssertTrue(harness.capture.refreshedWindows.isEmpty)
    }

    func testSourceActivationCancelsPendingSpaceRecovery() async {
        let harness = makeHarness()
        harness.windows.frontmost = true

        harness.workspace.emit(.activeSpaceChanged)
        harness.workspace.emit(
            .applicationActivated(ProcessInfo.processInfo.processIdentifier)
        )
        try? await Task.sleep(for: .milliseconds(260))

        XCTAssertEqual(harness.mapper.refreshCallCount, 0)
        XCTAssertEqual(harness.controller.session?.state, .interactive)
    }

    func testSiblingWindowFocusMakesPinnedWindowPassive() async {
        let harness = makeHarness()
        guard var current = harness.controller.session else {
            XCTFail("Missing test session")
            return
        }
        current.state = .interactive
        harness.controller.installSessionForTesting(current)
        harness.model.presentationState = .interactive
        harness.windows.frontmost = false
        harness.mapper.refreshResults = [
            .testWindow(availability: .available)
        ]

        harness.controller.handleAXEventForTesting(.focusedWindowChanged)

        await waitUntil { harness.controller.session?.state == .passive }
        XCTAssertEqual(harness.preview.showCount, 1)
        XCTAssertEqual(harness.model.presentationState, .passive)
    }

    func testPinnedWindowRegainingFocusMakesSessionInteractive() {
        let harness = makeHarness()
        harness.windows.frontmost = true

        harness.controller.handleAXEventForTesting(.focusedWindowChanged)

        XCTAssertEqual(harness.controller.session?.state, .interactive)
        XCTAssertEqual(harness.model.presentationState, .interactive)
    }

    func testOwnerActivationWithSiblingFocusedKeepsPreviewPassive() {
        let harness = makeHarness()
        harness.windows.frontmost = false

        harness.workspace.emit(
            .applicationActivated(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(harness.controller.session?.state, .passive)
        XCTAssertEqual(harness.model.presentationState, .passive)
    }

    func testOwnerActivationWithPinnedWindowFocusedBecomesInteractive() {
        let harness = makeHarness()
        harness.windows.frontmost = true

        harness.workspace.emit(
            .applicationActivated(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(harness.controller.session?.state, .interactive)
        XCTAssertEqual(harness.model.presentationState, .interactive)
    }

    func testFocusedWindowChangeIsIgnoredDuringHandoff() {
        let harness = makeHarness()
        guard var current = harness.controller.session else {
            XCTFail("Missing test session")
            return
        }
        current.state = .handingOff
        harness.controller.installSessionForTesting(current)
        harness.windows.frontmost = false

        harness.controller.handleAXEventForTesting(.focusedWindowChanged)

        XCTAssertEqual(harness.controller.session?.state, .handingOff)
    }

    func testSpaceChangeShowsPreviewWhenOwnerRemainsActiveOffSpace() async {
        let harness = makeHarness()
        guard var current = harness.controller.session else {
            XCTFail("Missing test session")
            return
        }
        current.state = .interactive
        current.crossSpaceCaptureState = .live
        harness.controller.installSessionForTesting(current)
        harness.model.presentationState = .interactive

        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil {
            harness.controller.session?.state == .passive
                && harness.controller.session?.crossSpaceCaptureState
                    == .offSpaceAwaitingChoice
        }

        XCTAssertEqual(harness.mapper.refreshCallCount, 1)
        XCTAssertEqual(harness.preview.showCount, 1)
        XCTAssertEqual(
            harness.preview.crossSpaceStates.last,
            .offSpaceAwaitingChoice
        )
    }

    func testOffSpaceGuidanceAppearsOnlyOncePerSession() async {
        let harness = makeHarness()

        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState
                == .offSpaceAwaitingChoice
        }
        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil { harness.mapper.refreshCallCount == 2 }
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState
                == .pausedOffSpace
        }

        XCTAssertEqual(
            harness.preview.crossSpaceStates.filter {
                $0 == .offSpaceAwaitingChoice
            }.count,
            1
        )
    }

    func testDecliningAllDesktopsKeepsPausedHandoffFallback() async {
        let harness = makeHarness()

        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState
                == .offSpaceAwaitingChoice
        }
        harness.preview.onAllDesktopsDeclined?()

        XCTAssertEqual(
            harness.controller.session?.crossSpaceCaptureState,
            .pausedOffSpace
        )
        XCTAssertEqual(harness.preview.crossSpaceStates.last, .pausedOffSpace)

        let pauseUpdateCount = harness.preview.pausedValues.count
        harness.capture.onHealthChanged?(.healthy)
        XCTAssertEqual(harness.preview.pausedValues.count, pauseUpdateCount)
    }

    func testConfirmedAllDesktopsRecoversExactWindow() async {
        let harness = makeHarness()
        harness.mapper.refreshResults = [
            .testWindow(availability: .offSpace),
            .testWindow(availability: .available)
        ]

        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState
                == .offSpaceAwaitingChoice
        }
        harness.preview.onAllDesktopsConfirmed?()
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState == .live
        }

        XCTAssertEqual(harness.mapper.refreshedWindowIDs, [42, 42])
        XCTAssertEqual(harness.capture.refreshedWindows.map(\.windowID), [42])
        XCTAssertEqual(harness.preview.crossSpaceStates.last, .live)
    }

    func testUnsuccessfulAllDesktopsConfirmationFallsBackToPaused() async {
        let harness = makeHarness()

        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState
                == .offSpaceAwaitingChoice
        }
        harness.preview.onAllDesktopsConfirmed?()
        await waitUntil(timeout: .seconds(2)) {
            harness.controller.session?.crossSpaceCaptureState
                == .pausedOffSpace
        }

        XCTAssertGreaterThan(harness.mapper.refreshCallCount, 1)
        XCTAssertTrue(harness.capture.refreshedWindows.isEmpty)
        XCTAssertEqual(harness.preview.crossSpaceStates.last, .pausedOffSpace)
    }

    func testAvailableStaticWindowRecoversWithoutGuidance() async {
        let harness = makeHarness()
        harness.mapper.refreshResults = [
            .testWindow(availability: .available)
        ]

        harness.workspace.emit(.activeSpaceChanged)
        await waitUntil {
            harness.controller.session?.crossSpaceCaptureState == .live
                && harness.capture.refreshedWindows.count == 1
        }

        XCTAssertFalse(
            harness.preview.crossSpaceStates.contains(
                .offSpaceAwaitingChoice
            )
        )
    }

    func testEveryPassiveEntryRebindsExactCaptureWindow() async {
        let harness = makeHarness()
        harness.mapper.refreshResults = [
            .testWindow(availability: .available)
        ]
        guard var current = harness.controller.session else {
            XCTFail("Missing test session")
            return
        }
        current.state = .interactive
        harness.controller.installSessionForTesting(current)
        harness.model.presentationState = .interactive

        harness.workspace.emit(
            .ownerDeactivated(ProcessInfo.processInfo.processIdentifier)
        )
        await waitUntil {
            harness.controller.session?.state == .passive
                && harness.capture.refreshedWindows.count == 1
        }

        XCTAssertEqual(harness.mapper.refreshedWindowIDs, [42])
        XCTAssertEqual(harness.capture.refreshedWindows.map(\.windowID), [42])
    }

    func testCaptureAuthorizationFailureStopsRecoveryAndUnpins() {
        let harness = makeHarness()
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        harness.capture.onFailure?(error)

        XCTAssertNil(harness.controller.session)
        XCTAssertEqual(
            harness.feedback.messages.last,
            PinFailure.permissionRevoked.localizedDescription
        )
        XCTAssertTrue(harness.feedback.unpinSoundValues.isEmpty)
    }

    func testIntentionalUnpinPlaysOneCueUsingSoundSetting() {
        let harness = makeHarness()

        harness.controller.togglePin()
        harness.controller.unpin(trigger: .userInitiated)

        XCTAssertEqual(harness.feedback.unpinSoundValues, [true])
    }

    func testIntentionalUnpinIsSilentWhenSoundDisabled() {
        let harness = makeHarness()
        harness.model.soundEnabled = false

        harness.controller.togglePin()

        XCTAssertEqual(harness.feedback.unpinSoundValues, [false])
    }

    func testAutomaticAndRepeatedUnpinDoNotPlayCue() {
        let harness = makeHarness()

        harness.controller.unpin(reason: .sourceClosed)
        harness.controller.unpin(trigger: .userInitiated)

        XCTAssertTrue(harness.feedback.unpinSoundValues.isEmpty)
    }

    private func makeHarness(installSession: Bool = true) -> Harness {
        let defaults = makeDefaults()
        let model = AppModel(defaults: defaults)
        let permissions = MockPermissions()
        let windows = MockWindows()
        let capture = MockCapture()
        let preview = MockPreview()
        let feedback = MockFeedback()
        let workspace = MockWorkspace()
        let mapper = MockMapper()
        let resolver = MockResolver()
        let controller = PinSessionController(
            model: model,
            permissions: permissions,
            resolver: resolver,
            mapper: mapper,
            windows: windows,
            capture: capture,
            preview: preview,
            feedback: feedback,
            workspace: workspace
        )
        let originalFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        windows.currentFrame = originalFrame
        preview.previewFrame = originalFrame
        if installSession {
            controller.installSessionForTesting(
                PinSession(
                    ownerPID: ProcessInfo.processInfo.processIdentifier,
                    bundleIdentifier: "com.halopin.tests",
                    applicationName: "Fixture",
                    title: "Window",
                    windowID: 42,
                    axWindow: AXUIElementCreateApplication(
                        ProcessInfo.processInfo.processIdentifier
                    ),
                    sourceFrame: originalFrame,
                    previewFrame: originalFrame,
                    state: .passive
                )
            )
            model.presentationState = .passive
        }
        return Harness(
            controller: controller,
            model: model,
            windows: windows,
            capture: capture,
            preview: preview,
            feedback: feedback,
            resolver: resolver,
            mapper: mapper,
            workspace: workspace,
            originalFrame: originalFrame
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PassiveGeometryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for asynchronous state")
    }
}

@MainActor
private struct Harness {
    let controller: PinSessionController
    let model: AppModel
    let windows: MockWindows
    let capture: MockCapture
    let preview: MockPreview
    let feedback: MockFeedback
    let resolver: MockResolver
    let mapper: MockMapper
    let workspace: MockWorkspace
    let originalFrame: CGRect
}

private enum TestFailure: Error {
    case rejected
    case unused
}

@MainActor
private final class MockPermissions: PermissionCoordinating {
    var hasAccessibilityPermission = true
    var hasScreenRecordingPermission = true

    func requestAccessibilityPermission() {}
    func requestScreenRecordingPermission() -> Bool { true }
    func openAccessibilitySettings() {}
    func openScreenRecordingSettings() {}
}

@MainActor
private final class MockResolver: FocusedWindowResolving {
    var result: ResolvedWindow?

    func resolveFocusedWindow() throws -> ResolvedWindow {
        guard let result else { throw TestFailure.unused }
        return result
    }
}

@MainActor
private final class MockMapper: WindowIdentityMapping {
    var refreshCallCount = 0
    var refreshedWindowIDs: [CGWindowID] = []
    var refreshResults: [CaptureWindowReference] = [
        .testWindow(availability: .offSpace)
    ]
    var mapResult: CaptureWindowReference?

    func map(_ window: ResolvedWindow) async throws -> CaptureWindowReference {
        guard let mapResult else { throw TestFailure.unused }
        return mapResult
    }

    func refresh(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) async throws -> CaptureWindowReference {
        refreshCallCount += 1
        refreshedWindowIDs.append(windowID)
        let index = min(refreshCallCount - 1, refreshResults.count - 1)
        return refreshResults[index]
    }
}

@MainActor
private final class MockWindows: WindowControlling {
    var currentFrame = CGRect.zero
    var acceptedFrame: CGRect?
    var applyError: Error?
    var appliedFrames: [CGRect] = []
    var raiseCount = 0
    var frontmost = false
    var minimized = false
    var fullscreen = false

    func frame(of window: AXUIElement) throws -> CGRect {
        currentFrame
    }

    func apply(frame: CGRect, to window: AXUIElement) throws -> CGRect {
        if let applyError {
            throw applyError
        }
        appliedFrames.append(frame)
        let accepted = acceptedFrame ?? frame
        currentFrame = accepted
        return accepted
    }

    func raise(_ window: AXUIElement) throws {
        raiseCount += 1
    }

    func isFrontmost(_ window: AXUIElement, ownerPID: pid_t) -> Bool {
        frontmost
    }

    func isMinimized(_ window: AXUIElement) -> Bool {
        minimized
    }

    func isFullscreen(_ window: AXUIElement) -> Bool {
        fullscreen
    }
}

@MainActor
private final class MockCapture: CaptureStreaming {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onHealthChanged: ((CaptureHealth) -> Void)?
    var onFailure: ((Error) -> Void)?
    var resizedFrames: [CGRect] = []
    var profiles: [CaptureProfile] = []
    var frameAdvanceCounts: [UInt64] = []
    var refreshedWindows: [CaptureWindowReference] = []
    var stopPreservationValues: [Bool] = []
    var healthMonitoringValues: [Bool] = []

    func start(
        window: CaptureWindowReference,
        profile: CaptureProfile
    ) async throws {
        profiles.append(profile)
    }

    func refresh(
        window: CaptureWindowReference,
        frame: CGRect,
        profile: CaptureProfile
    ) async throws {
        refreshedWindows.append(window)
        profiles.append(profile)
    }

    func update(frame: CGRect, profile: CaptureProfile) async throws {
        resizedFrames.append(frame)
        profiles.append(profile)
    }

    func awaitCompleteFrameAdvance(count: UInt64, timeout: Duration) async -> Bool {
        frameAdvanceCounts.append(count)
        return true
    }

    func validateInitialFrame(timeout: Duration) async throws {}
    func setHealthMonitoring(enabled: Bool, stallTimeout: Duration) {
        healthMonitoringValues.append(enabled)
    }
    func stop(preserveDisplayedFrame: Bool) async {
        stopPreservationValues.append(preserveDisplayedFrame)
    }
}

@MainActor
private final class MockPreview: PreviewPresenting {
    var previewFrame: CGRect?
    var onActivate: (() -> Void)?
    var onFrameChanged: ((CGRect) -> Void)?
    var onGeometryCommitted: ((PreviewGeometryCommit) -> Void)?
    var onAllDesktopsConfirmed: (() -> Void)?
    var onAllDesktopsDeclined: (() -> Void)?
    var sourceGeometryUpdates: [CGRect] = []
    var animatedFrames: [CGRect] = []
    var pausedValues: [Bool] = []
    var crossSpaceStates: [CrossSpaceCaptureState] = []
    var showCount = 0

    func configure(displayLayer: CALayer, frame: CGRect, aspectRatio: CGSize) {
        previewFrame = frame
    }

    func show() {
        showCount += 1
    }
    func hide() {}
    func freeze() {}
    func setPaused(_ paused: Bool) {
        pausedValues.append(paused)
    }

    func setCrossSpaceState(
        _ state: CrossSpaceCaptureState,
        applicationName: String
    ) {
        crossSpaceStates.append(state)
    }

    func updateSourceGeometry(_ frame: CGRect) {
        sourceGeometryUpdates.append(frame)
    }

    func animate(to frame: CGRect) {
        animatedFrames.append(frame)
        previewFrame = frame
    }

    func fadeOut(completion: @escaping @MainActor @Sendable () -> Void) {
        completion()
    }

    func clampToVisibleScreens() {}
    func tearDown() {}
}

@MainActor
private final class MockFeedback: FeedbackPresenting {
    var messages: [String] = []
    var unpinSoundValues: [Bool] = []

    func presentPinFeedback(around axFrame: CGRect, halo: Bool, sound: Bool) {}
    func presentUnpinFeedback(sound: Bool) {
        unpinSoundValues.append(sound)
    }

    func showHUD(_ message: String) {
        messages.append(message)
    }
}

@MainActor
private final class MockWorkspace: WorkspaceObserving {
    var onEvent: ((WorkspaceEvent) -> Void)?
    var startCount = 0
    var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func emit(_ event: WorkspaceEvent) {
        onEvent?(event)
    }
}

private extension CaptureWindowReference {
    static func testWindow(
        availability: SourceWindowAvailability
    ) -> CaptureWindowReference {
        CaptureWindowReference(
            windowID: 42,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600),
            availability: availability
        )
    }
}
