import AppKit
import ApplicationServices
import Foundation
import OSLog
import ScreenCaptureKit

@MainActor
final class PinSessionController {
    private let model: AppModel
    private let permissions: PermissionCoordinating
    private let resolver: FocusedWindowResolving
    private let mapper: WindowIdentityMapping
    private let windows: WindowControlling
    private let capture: CaptureStreaming
    private let preview: PreviewPresenting
    private let feedback: FeedbackPresenting
    private let workspace: WorkspaceObserving
    private let logger = Logger(subsystem: "com.halopin.HaloPin", category: "session")

    private(set) var session: PinSession?
    private var axObserver: AXWindowObserver?
    private var lastSampleDate: Date?
    private var stallTimer: Timer?
    private var operationTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var passiveGeometryTask: Task<Void, Never>?
    private var passiveGeometryRevision: UInt64 = 0
    private var isReconcilingPassiveGeometry = false
    private var handoffPendingAfterGeometry = false
    private var spaceRecoveryTask: Task<Void, Never>?
    private var spaceRecoveryRevision: UInt64 = 0
    private var lastSpaceRecoveryAttempt: Date?
    private var spaceGuidanceShown = false
    private var captureSuspended = false
    private var captureNeedsRecovery = false

    var onMenuNeedsUpdate: (() -> Void)?

    init(
        model: AppModel,
        permissions: PermissionCoordinating,
        resolver: FocusedWindowResolving = FocusedWindowResolver(),
        mapper: WindowIdentityMapping = ScreenCaptureWindowIdentityMapper(),
        windows: WindowControlling = AccessibilityWindowController(),
        capture: CaptureStreaming = ScreenCaptureEngine(),
        preview: PreviewPresenting = PreviewPanelController(),
        feedback: FeedbackPresenting = FeedbackPresenter(),
        workspace: WorkspaceObserving = WorkspaceObserver()
    ) {
        self.model = model
        self.permissions = permissions
        self.resolver = resolver
        self.mapper = mapper
        self.windows = windows
        self.capture = capture
        self.preview = preview
        self.feedback = feedback
        self.workspace = workspace

        preview.onActivate = { [weak self] in
            self?.beginHandoff()
        }
        preview.onFrameChanged = { [weak self] frame in
            guard let self else { return }
            self.session?.previewFrame = frame
        }
        preview.onGeometryCommitted = { [weak self] commit in
            self?.commitPassiveGeometry(commit)
        }
        preview.onAllDesktopsConfirmed = { [weak self] in
            self?.confirmAllDesktopsAssignment()
        }
        preview.onAllDesktopsDeclined = { [weak self] in
            self?.declineAllDesktopsAssignment()
        }
        capture.onSampleHeartbeat = { [weak self] in
            guard let self else { return }
            self.lastSampleDate = Date()
            if self.session?.crossSpaceCaptureState == .live {
                self.preview.setPaused(false)
            }
        }
        capture.onCompleteFrame = { [weak self] in
            guard let self,
                  self.session?.crossSpaceCaptureState == .live else {
                return
            }
            self.preview.setPaused(false)
        }
        capture.onFailure = { [weak self] error in
            self?.handleCaptureFailure(error)
        }

        workspace.onEvent = { [weak self] event in
            self?.handleWorkspaceEvent(event)
        }
        workspace.start()
        startStallTimer()
    }

    func togglePin() {
        if session != nil || model.presentationState == .resolving {
            if session != nil {
                unpin(trigger: .userInitiated)
            } else {
                cancelPendingPin()
            }
        } else {
            operationTask?.cancel()
            operationTask = Task { [weak self] in
                await self?.pinFocusedWindow()
            }
        }
    }

    func showPinnedWindow() {
        guard let session else { return }
        if session.state == .passive {
            beginHandoff()
        } else if let application = NSRunningApplication(processIdentifier: session.ownerPID) {
            _ = application.activate()
            try? windows.raise(session.axWindow)
        }
    }

    func unpin(
        reason: PinFailure? = nil,
        trigger: UnpinTrigger = .automatic
    ) {
        guard var current = session else { return }
        let wasPassive = current.state != .interactive
        current.state = .terminating
        session = current

        if let frame = preview.previewFrame, wasPassive {
            _ = try? windows.apply(frame: frame, to: current.axWindow)
        }

        operationTask?.cancel()
        operationTask = nil
        geometryTask?.cancel()
        geometryTask = nil
        cancelPassiveGeometry()
        cancelSpaceRecovery()
        axObserver = nil
        preview.tearDown()
        lastSampleDate = nil
        lastSpaceRecoveryAttempt = nil
        spaceGuidanceShown = false
        captureSuspended = false
        captureNeedsRecovery = false
        session = nil
        model.clearSession()

        Task { [capture] in
            await capture.stop()
        }

        if let reason {
            model.show(error: reason)
            feedback.showHUD(reason.localizedDescription)
        }
        if trigger == .userInitiated {
            feedback.presentUnpinFeedback(sound: model.soundEnabled)
        }
        onMenuNeedsUpdate?()
    }

    func refreshPermissions() {
        model.permissionsRevision += 1
        guard session != nil else { return }
        if !permissions.hasAccessibilityPermission || !permissions.hasScreenRecordingPermission {
            unpin(reason: .permissionRevoked)
        }
    }

    private func pinFocusedWindow() async {
        guard permissions.hasAccessibilityPermission else {
            permissions.requestAccessibilityPermission()
            fail(PinFailure.accessibilityPermissionMissing)
            return
        }
        guard permissions.hasScreenRecordingPermission else {
            _ = permissions.requestScreenRecordingPermission()
            fail(PinFailure.screenRecordingPermissionMissing)
            return
        }

        model.presentationState = .resolving
        do {
            let resolved = try resolver.resolveFocusedWindow()
            let captureWindow = try await mapper.map(resolved)

            try await capture.start(window: captureWindow)
            try await capture.validateInitialFrame(timeout: .seconds(2))
            preview.configure(
                displayLayer: capture.displayLayer,
                frame: resolved.frame,
                aspectRatio: resolved.frame.size
            )

            session = PinSession(
                ownerPID: resolved.ownerPID,
                bundleIdentifier: resolved.bundleIdentifier,
                applicationName: resolved.applicationName,
                title: resolved.title,
                windowID: captureWindow.windowID,
                axWindow: resolved.axWindow,
                sourceFrame: resolved.frame,
                previewFrame: resolved.frame,
                state: .interactive
            )
            spaceGuidanceShown = false
            captureNeedsRecovery = false
            model.pinnedWindowName = session?.displayName
            model.presentationState = .interactive
            lastSampleDate = Date()
            installAXObserver(for: resolved)
            onMenuNeedsUpdate?()

            feedback.presentPinFeedback(
                around: resolved.frame,
                halo: model.haloEnabled,
                sound: model.soundEnabled
            )
        } catch is CancellationError {
            await capture.stop()
            preview.tearDown()
            model.clearSession()
            onMenuNeedsUpdate?()
        } catch {
            logCaptureError("Pin failed", error: error)
            await capture.stop()
            preview.tearDown()
            if isScreenCaptureAuthorizationError(error) {
                fail(PinFailure.screenRecordingPermissionMissing)
            } else {
                fail(error)
            }
        }
    }

    private func becomePassive() {
        guard var current = session,
              current.state == .interactive || current.state == .becomingPassive else {
            return
        }
        guard !windows.isMinimized(current.axWindow) else {
            unpin(reason: .sourceMinimized)
            return
        }
        guard !windows.isFullscreen(current.axWindow) else {
            unpin(reason: .sourceFullscreen)
            return
        }

        geometryTask?.cancel()
        current.state = .becomingPassive
        current.crossSpaceCaptureState = .live
        preview.setCrossSpaceState(
            .live,
            applicationName: current.applicationName
        )
        if let frame = try? windows.frame(of: current.axWindow) {
            current.sourceFrame = frame
            current.previewFrame = frame
            preview.updateSourceGeometry(frame)
            preview.animate(to: frame)
        }
        session = current
        let targetFrame = current.previewFrame
        geometryTask = Task { [weak self] in
            await self?.finishBecomingPassive(at: targetFrame)
        }
    }

    private func finishBecomingPassive(at frame: CGRect) async {
        do {
            try await capture.resize(to: frame)
        } catch is CancellationError {
            return
        } catch {
            handleCaptureFailure(error)
        }
        _ = await capture.awaitCompleteFrameAdvance(
            count: 2,
            timeout: .milliseconds(120)
        )
        guard var current = session, current.state == .becomingPassive else {
            return
        }
        preview.show()
        current.state = .passive
        session = current
        model.presentationState = .passive
        onMenuNeedsUpdate?()
        // Always reacquire and recreate capture after the source deactivates.
        // ScreenCaptureKit can remain alive while still serving the surface
        // associated with a previous Space.
        if spaceRecoveryTask == nil {
            scheduleSpaceRecovery(after: .zero)
        }
    }

    private func becomeInteractive() {
        guard var current = session else { return }
        cancelSpaceRecovery()
        cancelPassiveGeometry()
        preview.hide()
        current.state = .interactive
        current.crossSpaceCaptureState = .live
        if let frame = try? windows.frame(of: current.axWindow) {
            current.sourceFrame = frame
            current.previewFrame = frame
        }
        session = current
        model.presentationState = .interactive
        onMenuNeedsUpdate?()
    }

    private func beginHandoff() {
        guard session?.state == .passive else { return }
        cancelSpaceRecovery()
        if isReconcilingPassiveGeometry {
            handoffPendingAfterGeometry = true
            return
        }
        startHandoff()
    }

    private func startHandoff() {
        guard var current = session, current.state == .passive else { return }
        current.state = .handingOff
        current.crossSpaceCaptureState = .live
        preview.setCrossSpaceState(
            .live,
            applicationName: current.applicationName
        )
        if let frame = preview.previewFrame {
            current.previewFrame = frame
        }
        session = current
        preview.freeze()

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            await self?.performHandoff()
        }
    }

    private func commitPassiveGeometry(_ commit: PreviewGeometryCommit) {
        guard var current = session, current.state == .passive else { return }
        current.previewFrame = commit.frame
        session = current
        guard model.nativeGeometrySyncEnabled else { return }

        passiveGeometryRevision &+= 1
        let revision = passiveGeometryRevision
        passiveGeometryTask?.cancel()
        isReconcilingPassiveGeometry = true
        passiveGeometryTask = Task { [weak self] in
            await self?.reconcilePassiveGeometry(
                commit,
                windowID: current.windowID,
                revision: revision
            )
        }
    }

    private func reconcilePassiveGeometry(
        _ commit: PreviewGeometryCommit,
        windowID: CGWindowID,
        revision: UInt64
    ) async {
        defer {
            finishPassiveGeometry(revision: revision)
        }

        guard isCurrentPassiveGeometry(windowID: windowID, revision: revision),
              let current = session else {
            return
        }
        guard !windows.isMinimized(current.axWindow) else {
            unpin(reason: .sourceMinimized)
            return
        }
        guard !windows.isFullscreen(current.axWindow) else {
            unpin(reason: .sourceFullscreen)
            return
        }

        let acceptedImmediately: CGRect
        do {
            acceptedImmediately = try windows.apply(
                frame: commit.frame,
                to: current.axWindow
            )
        } catch {
            logger.error(
                "Passive geometry synchronization failed: \(String(describing: error), privacy: .private)"
            )
            feedback.showHUD(
                "This app could not resize while inactive. Using a scaled preview."
            )
            return
        }

        let acceptedFrame = await settledFrame(
            startingAt: acceptedImmediately,
            window: current.axWindow,
            windowID: windowID,
            revision: revision
        )
        guard isCurrentPassiveGeometry(windowID: windowID, revision: revision),
              var latest = session else {
            return
        }

        latest.sourceFrame = acceptedFrame
        latest.previewFrame = acceptedFrame
        session = latest
        preview.updateSourceGeometry(acceptedFrame)
        if let visibleFrame = preview.previewFrame,
           !visibleFrame.approximatelyEquals(acceptedFrame, tolerance: 2) {
            preview.animate(to: acceptedFrame)
        }

        do {
            try await capture.resize(to: acceptedFrame)
        } catch is CancellationError {
            return
        } catch {
            handleCaptureFailure(error)
            return
        }
        guard isCurrentPassiveGeometry(windowID: windowID, revision: revision) else {
            return
        }
        _ = await capture.awaitCompleteFrameAdvance(
            count: 2,
            timeout: .milliseconds(120)
        )
    }

    private func settledFrame(
        startingAt initialFrame: CGRect,
        window: AXUIElement,
        windowID: CGWindowID,
        revision: UInt64
    ) async -> CGRect {
        var acceptedFrame = initialFrame
        var consecutiveStableReads = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(120))

        while clock.now < deadline, consecutiveStableReads < 2 {
            try? await Task.sleep(for: .milliseconds(16))
            guard isCurrentPassiveGeometry(windowID: windowID, revision: revision) else {
                return acceptedFrame
            }
            guard let nextFrame = try? windows.frame(of: window) else {
                break
            }
            if nextFrame.approximatelyEquals(acceptedFrame, tolerance: 1) {
                consecutiveStableReads += 1
            } else {
                acceptedFrame = nextFrame
                consecutiveStableReads = 0
            }
        }
        return acceptedFrame
    }

    private func isCurrentPassiveGeometry(
        windowID: CGWindowID,
        revision: UInt64
    ) -> Bool {
        !Task.isCancelled
            && passiveGeometryRevision == revision
            && session?.windowID == windowID
            && session?.state == .passive
    }

    private func finishPassiveGeometry(revision: UInt64) {
        guard passiveGeometryRevision == revision else { return }
        passiveGeometryTask = nil
        isReconcilingPassiveGeometry = false
        guard handoffPendingAfterGeometry else { return }
        handoffPendingAfterGeometry = false
        startHandoff()
    }

    private func cancelPassiveGeometry() {
        passiveGeometryRevision &+= 1
        passiveGeometryTask?.cancel()
        passiveGeometryTask = nil
        isReconcilingPassiveGeometry = false
        handoffPendingAfterGeometry = false
    }

    #if DEBUG
    func installSessionForTesting(_ session: PinSession) {
        self.session = session
    }
    #endif

    private func performHandoff() async {
        guard var current = session, current.state == .handingOff else { return }
        do {
            let acceptedFrame = try windows.apply(
                frame: current.previewFrame,
                to: current.axWindow
            )
            current.sourceFrame = acceptedFrame
            current.previewFrame = acceptedFrame
            session = current
            preview.updateSourceGeometry(acceptedFrame)
            if let visibleFrame = preview.previewFrame,
               !visibleFrame.approximatelyEquals(acceptedFrame, tolerance: 2) {
                preview.animate(to: acceptedFrame)
            }

            guard let application = NSRunningApplication(processIdentifier: current.ownerPID),
                  application.activate() else {
                throw PinFailure.activationFailed
            }
            try windows.raise(current.axWindow)

            let activated = await waitForActivation(
                application,
                window: current.axWindow,
                timeout: 2.5
            )
            if !activated {
                try windows.raise(current.axWindow)
                let activatedAfterRetry = await waitForActivation(
                    application,
                    window: current.axWindow,
                    timeout: 0.5
                )
                if !activatedAfterRetry {
                    throw PinFailure.activationFailed
                }
            }

            await withCheckedContinuation { continuation in
                preview.fadeOut {
                    continuation.resume()
                }
            }
            guard var latest = session else { return }
            latest.state = .interactive
            session = latest
            model.presentationState = .interactive
            onMenuNeedsUpdate?()
        } catch {
            logger.error("Handoff failed: \(String(describing: error), privacy: .private)")
            guard var latest = session else { return }
            latest.state = .passive
            session = latest
            preview.show()
            model.show(error: error)
            feedback.showHUD(error.localizedDescription)
            onMenuNeedsUpdate?()
        }
    }

    private func waitForActivation(
        _ application: NSRunningApplication,
        window: AXUIElement,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if application.isActive,
               windows.isFrontmost(window, ownerPID: application.processIdentifier) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        return application.isActive
            && windows.isFrontmost(window, ownerPID: application.processIdentifier)
    }

    private func installAXObserver(for resolved: ResolvedWindow) {
        axObserver = try? AXWindowObserver(
            pid: resolved.ownerPID,
            window: resolved.axWindow
        ) { [weak self] event in
            self?.handleAXEvent(event)
        }
    }

    private func handleAXEvent(_ event: AXWindowObserver.Event) {
        guard let current = session else { return }
        switch event {
        case .destroyed:
            unpin(reason: .sourceClosed)
        case .minimized:
            unpin(reason: .sourceMinimized)
        case .movedOrResized:
            guard current.state == .interactive else { return }
            scheduleInteractiveGeometryRefresh()
        case .titleChanged:
            break
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        logCaptureError("Capture stopped", error: error)
        guard let current = session else { return }
        if isScreenCaptureAuthorizationError(error) {
            unpin(reason: .permissionRevoked)
            return
        }
        captureNeedsRecovery = true
        guard current.crossSpaceCaptureState == .live
                || current.crossSpaceCaptureState == .recovering else {
            return
        }
        preview.setPaused(true)
        model.presentationState = .warning(PinFailure.captureFailed.localizedDescription)
        onMenuNeedsUpdate?()
        if session?.state == .passive, spaceRecoveryTask == nil {
            scheduleSpaceRecovery(after: .zero)
        }
    }

    private func fail(_ error: Error) {
        model.show(error: error)
        feedback.showHUD(error.localizedDescription)
        onMenuNeedsUpdate?()
    }

    private func cancelPendingPin() {
        operationTask?.cancel()
        operationTask = nil
        preview.tearDown()
        model.clearSession()
        onMenuNeedsUpdate?()
        Task { [capture] in
            await capture.stop()
        }
    }

    private func scheduleInteractiveGeometryRefresh() {
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.refreshInteractiveGeometry()
        }
    }

    private func refreshInteractiveGeometry() async {
        guard var current = session, current.state == .interactive else { return }
        if windows.isFullscreen(current.axWindow) {
            unpin(reason: .sourceFullscreen)
            return
        }
        guard let frame = try? windows.frame(of: current.axWindow) else { return }
        current.sourceFrame = frame
        current.previewFrame = frame
        session = current
        preview.updateSourceGeometry(frame)
        preview.animate(to: frame)
        do {
            try await capture.resize(to: frame)
        } catch {
            handleCaptureFailure(error)
        }
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent) {
        switch event {
        case let .ownerDeactivated(pid) where pid == session?.ownerPID:
            becomePassive()
        case let .applicationActivated(pid) where pid == session?.ownerPID:
            if session?.state != .handingOff {
                becomeInteractive()
            }
        case let .applicationTerminated(pid) where pid == session?.ownerPID:
            unpin(reason: .sourceClosed)
        case let .applicationHidden(pid) where pid == session?.ownerPID:
            unpin(reason: .sourceHidden)
        case .activeSpaceChanged:
            // A source application can remain active after switching to a
            // Space where its pinned window is absent. Do not rely solely on
            // an application-deactivation notification to enter passive mode.
            captureNeedsRecovery = true
            if session?.state == .passive || session?.state == .becomingPassive {
                preview.show()
            }
            scheduleSpaceRecovery(after: .milliseconds(180))
        case .screensChanged:
            preview.clampToVisibleScreens()
            if session?.state == .passive {
                scheduleSpaceRecovery(after: .milliseconds(180))
            }
        case .suspend:
            suspendCapture()
        case .resume:
            Task { [weak self] in
                await self?.resumeCapture()
            }
        default:
            break
        }
    }

    private func scheduleSpaceRecovery(
        after delay: Duration,
        pollForAvailability: Bool = false
    ) {
        guard session != nil else { return }
        spaceRecoveryRevision &+= 1
        let revision = spaceRecoveryRevision
        spaceRecoveryTask?.cancel()
        spaceRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.recoverCaptureAfterSpaceChange(
                revision: revision,
                pollForAvailability: pollForAvailability
            )
        }
    }

    private func recoverCaptureAfterSpaceChange(
        revision: UInt64,
        pollForAvailability: Bool
    ) async {
        defer {
            finishSpaceRecovery(revision: revision)
        }

        let clock = ContinuousClock()
        let passiveDeadline = clock.now.advanced(by: .milliseconds(300))
        while session?.state == .interactive
                || session?.state == .becomingPassive,
              clock.now < passiveDeadline {
            try? await Task.sleep(for: .milliseconds(25))
            guard isCurrentSpaceRecovery(revision: revision) else { return }
        }
        guard isCurrentSpaceRecovery(revision: revision),
              var current = session,
              current.state == .passive || current.state == .interactive else {
            return
        }

        if current.state == .passive {
            cancelPassiveGeometry()
        }
        if let latestFrame = try? windows.frame(of: current.axWindow) {
            current.sourceFrame = latestFrame
            session = current
        }
        lastSpaceRecoveryAttempt = Date()
        updateCrossSpaceState(.recovering)

        do {
            var refreshedWindow = try await mapper.refresh(
                windowID: current.windowID,
                ownerPID: current.ownerPID
            )
            if pollForAvailability,
               refreshedWindow.availability == .offSpace {
                let availabilityDeadline = clock.now.advanced(by: .seconds(1))
                while refreshedWindow.availability == .offSpace,
                      clock.now < availabilityDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                    guard isCurrentSpaceRecovery(revision: revision) else {
                        return
                    }
                    refreshedWindow = try await mapper.refresh(
                        windowID: current.windowID,
                        ownerPID: current.ownerPID
                    )
                }
            }
            guard isCurrentSpaceRecovery(revision: revision),
                  var latest = session else {
                return
            }
            if latest.state == .interactive {
                guard refreshedWindow.availability == .offSpace else {
                    captureNeedsRecovery = false
                    updateCrossSpaceState(.live)
                    return
                }
                latest.state = .passive
                session = latest
                preview.show()
                enterOffSpaceFallback()
                return
            }
            guard latest.state == .passive else { return }
            guard refreshedWindow.availability == .available else {
                enterOffSpaceFallback()
                return
            }
            try await capture.refresh(
                window: refreshedWindow,
                frame: latest.sourceFrame
            )
            guard isCurrentSpaceRecovery(revision: revision) else { return }
            captureNeedsRecovery = false
            lastSampleDate = Date()
            preview.setPaused(false)
            updateCrossSpaceState(.live)
        } catch is CancellationError {
            return
        } catch where isScreenCaptureAuthorizationError(error) {
            guard isCurrentSpaceRecovery(revision: revision) else { return }
            unpin(reason: .permissionRevoked)
        } catch let failure as PinFailure where failure == .windowMappingFailed {
            guard isCurrentSpaceRecovery(revision: revision) else { return }
            unpin(reason: .sourceClosed)
        } catch {
            guard isCurrentSpaceRecovery(revision: revision) else { return }
            logCaptureError("Space capture recovery failed", error: error)
            updateCrossSpaceState(.live)
            preview.setPaused(true)
            model.presentationState = .warning(
                PinFailure.captureFailed.localizedDescription
            )
            feedback.showHUD("Live preview paused after switching Spaces.")
            onMenuNeedsUpdate?()
        }
    }

    private func confirmAllDesktopsAssignment() {
        guard session?.state == .passive else { return }
        spaceGuidanceShown = true
        updateCrossSpaceState(.recovering)
        scheduleSpaceRecovery(
            after: .zero,
            pollForAvailability: true
        )
    }

    private func declineAllDesktopsAssignment() {
        guard session?.state == .passive else { return }
        spaceGuidanceShown = true
        updateCrossSpaceState(.pausedOffSpace)
    }

    private func enterOffSpaceFallback() {
        // The current stream may be stopped or bound to the old Space. Keep a
        // recovery pending so a later native handoff/deactivation can restore
        // live capture once the source is visible again.
        captureNeedsRecovery = true
        lastSampleDate = nil
        preview.setPaused(false)
        if spaceGuidanceShown {
            updateCrossSpaceState(.pausedOffSpace)
        } else {
            spaceGuidanceShown = true
            updateCrossSpaceState(.offSpaceAwaitingChoice)
        }
    }

    private func updateCrossSpaceState(_ state: CrossSpaceCaptureState) {
        guard var current = session else { return }
        current.crossSpaceCaptureState = state
        session = current
        preview.setCrossSpaceState(
            state,
            applicationName: current.applicationName
        )
        switch state {
        case .live, .recovering:
            model.presentationState =
                current.state == .interactive ? .interactive : .passive
        case .offSpaceAwaitingChoice, .pausedOffSpace:
            model.presentationState = .warning(
                "Source is off Desktop; preview paused."
            )
        }
        onMenuNeedsUpdate?()
    }

    private func isScreenCaptureAuthorizationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    private func logCaptureError(_ message: String, error: Error) {
        let nsError = error as NSError
        logger.error(
            "\(message, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
    }

    private func isCurrentSpaceRecovery(revision: UInt64) -> Bool {
        !Task.isCancelled
            && spaceRecoveryRevision == revision
            && session != nil
    }

    private func finishSpaceRecovery(revision: UInt64) {
        guard spaceRecoveryRevision == revision else { return }
        spaceRecoveryTask = nil
    }

    private func cancelSpaceRecovery() {
        spaceRecoveryRevision &+= 1
        spaceRecoveryTask?.cancel()
        spaceRecoveryTask = nil
    }

    private func startStallTimer() {
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.session?.state == .passive,
                      self.session?.crossSpaceCaptureState == .live else {
                    return
                }
                let stalled = self.lastSampleDate.map {
                    Date().timeIntervalSince($0) > 1.5
                } ?? true
                self.preview.setPaused(stalled)
                guard stalled, self.spaceRecoveryTask == nil else { return }
                let recoveryAllowed = self.lastSpaceRecoveryAttempt.map {
                    Date().timeIntervalSince($0) > 2
                } ?? true
                if recoveryAllowed {
                    self.scheduleSpaceRecovery(after: .zero)
                }
            }
        }
    }

    private func suspendCapture() {
        guard session != nil, !captureSuspended else { return }
        cancelSpaceRecovery()
        captureSuspended = true
        preview.setPaused(true)
        Task { [capture] in
            await capture.stop()
        }
    }

    private func resumeCapture() async {
        guard captureSuspended,
              let current = session else {
            return
        }
        guard permissions.hasAccessibilityPermission,
              permissions.hasScreenRecordingPermission else {
            unpin(reason: .permissionRevoked)
            return
        }
        do {
            let refreshedWindow = try await mapper.refresh(
                windowID: current.windowID,
                ownerPID: current.ownerPID
            )
            guard refreshedWindow.availability == .available else {
                captureSuspended = false
                enterOffSpaceFallback()
                return
            }
            try await capture.start(window: refreshedWindow)
            try await capture.validateInitialFrame(timeout: .seconds(2))
            captureSuspended = false
            captureNeedsRecovery = false
            lastSampleDate = Date()
            preview.setPaused(false)
            updateCrossSpaceState(.live)
        } catch {
            if isScreenCaptureAuthorizationError(error) {
                unpin(reason: .permissionRevoked)
            } else {
                unpin(reason: .captureFailed)
            }
        }
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
