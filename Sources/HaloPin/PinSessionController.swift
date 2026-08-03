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
    private let captureLifecycle: CaptureLifecycleManaging
    private let preview: PreviewPresenting
    private let feedback: FeedbackPresenting
    private let workspace: WorkspaceObserving
    private let timing: SessionTiming
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.halopin.HaloPin", category: "session")
    private let signposter = OSSignposter(
        subsystem: "com.halopin.HaloPin",
        category: "performance"
    )

    private(set) var session: PinSession?
    private var axObserver: AXWindowObserver?
    private var operationTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var captureModeTask: Task<Void, Never>?
    private var passiveGeometryTask: Task<Void, Never>?
    private var passiveGeometryRevision: UInt64 = 0
    private var isReconcilingPassiveGeometry = false
    private var handoffPendingAfterGeometry = false
    private var spaceRecoveryTask: Task<Void, Never>?
    private var spaceRecoveryRevision: UInt64 = 0
    private var lastSpaceRecoveryAttempt: ContinuousClock.Instant?
    private var spaceGuidanceShown = false
    private var captureSuspended = false

    var onMenuNeedsUpdate: (() -> Void)?

    init(
        model: AppModel,
        permissions: PermissionCoordinating,
        resolver: FocusedWindowResolving = FocusedWindowResolver(),
        mapper: WindowIdentityMapping? = nil,
        windows: WindowControlling = AccessibilityWindowController(),
        capture: CaptureStreaming? = nil,
        captureLifecycle: CaptureLifecycleManaging? = nil,
        preview: PreviewPresenting = PreviewPanelController(),
        feedback: FeedbackPresenting = FeedbackPresenter(),
        workspace: WorkspaceObserving = WorkspaceObserver(),
        timing: SessionTiming = .production
    ) {
        self.model = model
        self.permissions = permissions
        self.resolver = resolver
        self.mapper = mapper ?? ScreenCaptureWindowIdentityMapper(timing: timing)
        self.windows = windows
        let captureService = capture ?? ScreenCaptureEngine(timing: timing)
        self.captureLifecycle = captureLifecycle
            ?? CaptureLifecycleCoordinator(
                capture: captureService,
                timing: timing
            )
        self.preview = preview
        self.feedback = feedback
        self.workspace = workspace
        self.timing = timing

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
        self.captureLifecycle.onHealthChanged = { [weak self] health in
            self?.handleCaptureHealth(health)
        }
        self.captureLifecycle.onFailure = { [weak self] error in
            self?.handleCaptureFailure(error)
        }

        workspace.onEvent = { [weak self] event in
            self?.handleWorkspaceEvent(event)
        }
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
        guard transitionSession(to: .terminating) else { return }
        current = session ?? current

        if let frame = preview.previewFrame, wasPassive {
            _ = try? windows.apply(frame: frame, to: current.axWindow)
        }

        operationTask?.cancel()
        operationTask = nil
        geometryTask?.cancel()
        geometryTask = nil
        captureModeTask?.cancel()
        captureModeTask = nil
        cancelPassiveGeometry()
        cancelSpaceRecovery()
        axObserver = nil
        workspace.stop()
        preview.tearDown()
        lastSpaceRecoveryAttempt = nil
        spaceGuidanceShown = false
        captureSuspended = false
        session = nil
        model.clearSession()

        captureLifecycle.requestStop()

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
        let interval = signposter.beginInterval("Pin Establishment")
        defer { signposter.endInterval("Pin Establishment", interval) }
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

            session = PinSession(
                ownerPID: resolved.ownerPID,
                bundleIdentifier: resolved.bundleIdentifier,
                applicationName: resolved.applicationName,
                title: resolved.title,
                windowID: captureWindow.windowID,
                axWindow: resolved.axWindow,
                sourceFrame: resolved.frame,
                previewFrame: resolved.frame,
                state: .resolving
            )
            try await captureLifecycle.prepare(window: captureWindow)
            preview.configure(
                displayLayer: captureLifecycle.displayLayer,
                frame: resolved.frame,
                aspectRatio: resolved.frame.size
            )

            guard transitionSession(to: .interactive) else {
                throw PinFailure.captureFailed
            }
            spaceGuidanceShown = false
            model.pinnedWindowName = session?.displayName
            model.presentationState = .interactive
            installAXObserver(for: resolved)
            workspace.start()
            onMenuNeedsUpdate?()

            feedback.presentPinFeedback(
                around: resolved.frame,
                halo: model.haloEnabled,
                sound: model.soundEnabled
            )
            await captureLifecycle.enterWarm(frame: resolved.frame)
        } catch is CancellationError {
            captureLifecycle.requestStop()
            await captureLifecycle.waitUntilStopped()
            workspace.stop()
            preview.tearDown()
            session = nil
            model.clearSession()
            onMenuNeedsUpdate?()
        } catch {
            logCaptureError("Pin failed", error: error)
            captureLifecycle.requestStop()
            await captureLifecycle.waitUntilStopped()
            workspace.stop()
            preview.tearDown()
            session = nil
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
        guard transitionSession(to: .becomingPassive) else { return }
        current = session ?? current
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
        geometryTask = Task { [weak self] in
            await self?.finishBecomingPassive()
        }
    }

    private func finishBecomingPassive() async {
        let interval = signposter.beginInterval("Passive Entry")
        defer { signposter.endInterval("Passive Entry", interval) }
        guard session?.state == .becomingPassive else {
            return
        }
        preview.show()
        guard transitionSession(to: .passive) else { return }
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
        guard transitionSession(to: .interactive) else { return }
        current = session ?? current
        current.crossSpaceCaptureState = .live
        if let frame = try? windows.frame(of: current.axWindow) {
            current.sourceFrame = frame
            current.previewFrame = frame
        }
        session = current
        model.presentationState = .interactive
        onMenuNeedsUpdate?()
        captureModeTask?.cancel()
        let frame = current.sourceFrame
        captureModeTask = Task { [weak self] in
            await self?.captureLifecycle.enterWarm(frame: frame)
        }
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
        guard transitionSession(to: .handingOff) else { return }
        current = session ?? current
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
            try await captureLifecycle.updateGeometry(acceptedFrame)
        } catch is CancellationError {
            return
        } catch {
            handleCaptureFailure(error)
            return
        }
        guard isCurrentPassiveGeometry(windowID: windowID, revision: revision) else {
            return
        }
        _ = await captureLifecycle.awaitCompleteFrameAdvance(
            count: 2,
            timeout: timing.passiveFrameWait
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
        let deadline = clock.now.advanced(by: timing.geometrySettleTimeout)

        while clock.now < deadline, consecutiveStableReads < 2 {
            try? await Task.sleep(for: timing.geometryPollInterval)
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

    // Internal test seam. Whole-module optimization removes it from the
    // release executable because production code never references it.
    func installSessionForTesting(_ session: PinSession) {
        self.session = session
    }

    private func performHandoff() async {
        let interval = signposter.beginInterval("Native Handoff")
        defer { signposter.endInterval("Native Handoff", interval) }
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
                timeout: timing.handoffActivationTimeout
            )
            if !activated {
                try windows.raise(current.axWindow)
                let activatedAfterRetry = await waitForActivation(
                    application,
                    window: current.axWindow,
                    timeout: timing.handoffRetryTimeout
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
            guard transitionSession(to: .interactive),
                  let latest = session else {
                return
            }
            model.presentationState = .interactive
            onMenuNeedsUpdate?()
            await captureLifecycle.enterWarm(frame: latest.sourceFrame)
        } catch {
            logger.error("Handoff failed: \(String(describing: error), privacy: .private)")
            guard transitionSession(to: .passive) else { return }
            preview.show()
            model.show(error: error)
            feedback.showHUD(error.localizedDescription)
            onMenuNeedsUpdate?()
        }
    }

    private func waitForActivation(
        _ application: NSRunningApplication,
        window: AXUIElement,
        timeout: Duration
    ) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if application.isActive,
               windows.isFrontmost(window, ownerPID: application.processIdentifier) {
                return true
            }
            try? await Task.sleep(for: timing.handoffPollInterval)
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
        case .focusedWindowChanged:
            reconcilePinnedWindowFocus()
        }
    }

    private func reconcilePinnedWindowFocus() {
        guard let current = session, current.state != .handingOff else { return }

        if windows.isFrontmost(current.axWindow, ownerPID: current.ownerPID) {
            guard current.state == .passive || current.state == .becomingPassive else {
                return
            }
            becomeInteractive()
        } else {
            guard current.state == .interactive || current.state == .becomingPassive else {
                return
            }
            becomePassive()
        }
    }

    // Internal test seam. Whole-module optimization removes it from the
    // release executable because production code never references it.
    func handleAXEventForTesting(_ event: AXWindowObserver.Event) {
        handleAXEvent(event)
    }

    private func handleCaptureFailure(_ error: Error) {
        logCaptureError("Capture stopped", error: error)
        guard let current = session else { return }
        if isScreenCaptureAuthorizationError(error) {
            unpin(reason: .permissionRevoked)
            return
        }
        guard current.crossSpaceCaptureState == .live
                || current.crossSpaceCaptureState == .recovering else {
            return
        }
        preview.setPaused(true)
        model.showWarning(PinFailure.captureFailed.localizedDescription)
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
        workspace.stop()
        session = nil
        model.clearSession()
        onMenuNeedsUpdate?()
        captureLifecycle.requestStop()
    }

    private func scheduleInteractiveGeometryRefresh() {
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timing.interactiveGeometryDebounce)
            guard !Task.isCancelled else { return }
            await self.refreshInteractiveGeometry()
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
            try await captureLifecycle.updateGeometry(frame)
        } catch {
            handleCaptureFailure(error)
        }
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent) {
        switch event {
        case let .ownerDeactivated(pid) where pid == session?.ownerPID:
            becomePassive()
        case let .applicationActivated(pid) where pid == session?.ownerPID:
            reconcilePinnedWindowFocus()
        case let .applicationTerminated(pid) where pid == session?.ownerPID:
            unpin(reason: .sourceClosed)
        case let .applicationHidden(pid) where pid == session?.ownerPID:
            unpin(reason: .sourceHidden)
        case .activeSpaceChanged:
            // A source application can remain active after switching to a
            // Space where its pinned window is absent. Do not rely solely on
            // an application-deactivation notification to enter passive mode.
            if session?.state == .passive || session?.state == .becomingPassive {
                preview.show()
            }
            scheduleSpaceRecovery(after: timing.spaceRecoveryDebounce)
        case .screensChanged:
            preview.clampToVisibleScreens()
            if session?.state == .passive {
                scheduleSpaceRecovery(after: timing.spaceRecoveryDebounce)
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
        let passiveDeadline = clock.now.advanced(
            by: timing.spaceTransitionSettleTimeout
        )
        while session?.state == .interactive
                || session?.state == .becomingPassive,
              clock.now < passiveDeadline {
            try? await Task.sleep(for: timing.spaceStatePollInterval)
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
        lastSpaceRecoveryAttempt = clock.now
        updateCrossSpaceState(.recovering)

        do {
            var refreshedWindow = try await mapper.refresh(
                windowID: current.windowID,
                ownerPID: current.ownerPID
            )
            if pollForAvailability,
               refreshedWindow.availability == .offSpace {
                let availabilityDeadline = clock.now.advanced(
                    by: timing.availabilityPollTimeout
                )
                while refreshedWindow.availability == .offSpace,
                      clock.now < availabilityDeadline {
                    try await Task.sleep(for: timing.availabilityPollInterval)
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
                  let latest = session else {
                return
            }
            if latest.state == .interactive {
                guard refreshedWindow.availability == .offSpace else {
                    updateCrossSpaceState(.live)
                    return
                }
                guard transitionSession(to: .becomingPassive),
                      transitionSession(to: .passive) else {
                    return
                }
                preview.show()
                enterOffSpaceFallback()
                return
            }
            guard latest.state == .passive else { return }
            guard refreshedWindow.availability == .available else {
                enterOffSpaceFallback()
                return
            }
            let interval = signposter.beginInterval("Capture Rebind")
            defer { signposter.endInterval("Capture Rebind", interval) }
            try await captureLifecycle.enterLive(
                window: refreshedWindow,
                frame: latest.sourceFrame
            )
            signposter.emitEvent("First Fresh Frame")
            guard isCurrentSpaceRecovery(revision: revision) else { return }
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
            model.showWarning(
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
        preview.setPaused(false)
        if spaceGuidanceShown {
            updateCrossSpaceState(.pausedOffSpace)
        } else {
            spaceGuidanceShown = true
            updateCrossSpaceState(.offSpaceAwaitingChoice)
        }
        captureModeTask?.cancel()
        captureModeTask = Task { [weak self] in
            await self?.captureLifecycle.pausePreservingFrame()
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
            model.showWarning(
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

    @discardableResult
    private func transitionSession(to next: PinState) -> Bool {
        guard var current = session else { return false }
        guard current.state.canTransition(to: next) else {
            logger.error(
                "Rejected pin-state transition: \(String(describing: current.state), privacy: .public) -> \(String(describing: next), privacy: .public)"
            )
            return false
        }
        current.state = next
        session = current
        return true
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

    private func handleCaptureHealth(_ health: CaptureHealth) {
        guard session?.state == .passive,
              session?.crossSpaceCaptureState == .live else {
            return
        }
        switch health {
        case .healthy:
            preview.setPaused(false)
        case .stalled:
            preview.setPaused(true)
            guard spaceRecoveryTask == nil else { return }
            let recoveryAllowed = lastSpaceRecoveryAttempt.map {
                $0.duration(to: clock.now) > timing.captureRecoveryCooldown
            } ?? true
            if recoveryAllowed {
                scheduleSpaceRecovery(after: .zero)
            }
        case .stopped:
            if !captureSuspended {
                preview.setPaused(true)
            }
        }
    }

    private func suspendCapture() {
        guard session != nil, !captureSuspended else { return }
        cancelSpaceRecovery()
        captureSuspended = true
        preview.setPaused(true)
        captureModeTask?.cancel()
        captureModeTask = Task { [weak self] in
            await self?.captureLifecycle.suspend()
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
            if current.state == .passive {
                try await captureLifecycle.enterLive(
                    window: refreshedWindow,
                    frame: current.sourceFrame
                )
            } else {
                try await captureLifecycle.prepare(window: refreshedWindow)
                await captureLifecycle.enterWarm(frame: current.sourceFrame)
            }
            captureSuspended = false
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
