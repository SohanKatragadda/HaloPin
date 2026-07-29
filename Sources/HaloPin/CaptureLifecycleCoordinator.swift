import AVFoundation
import Foundation

@MainActor
final class CaptureLifecycleCoordinator: CaptureLifecycleManaging {
    private let capture: CaptureStreaming
    private let timing: SessionTiming
    private var operationTail: Task<Void, Never>?

    private(set) var mode: CaptureLifecycleMode = .stopped

    var displayLayer: AVSampleBufferDisplayLayer {
        capture.displayLayer
    }

    var onHealthChanged: ((CaptureHealth) -> Void)? {
        didSet {
            capture.onHealthChanged = { [weak self] health in
                self?.onHealthChanged?(health)
            }
        }
    }

    var onFailure: ((Error) -> Void)? {
        didSet {
            capture.onFailure = { [weak self] error in
                self?.onFailure?(error)
            }
        }
    }

    init(
        capture: CaptureStreaming,
        timing: SessionTiming = .production
    ) {
        self.capture = capture
        self.timing = timing
    }

    func prepare(window: CaptureWindowReference) async throws {
        try await serialize {
            self.capture.setHealthMonitoring(
                enabled: false,
                stallTimeout: self.timing.captureStallTimeout
            )
            try await self.capture.start(window: window, profile: .live)
            try await self.capture.validateInitialFrame(
                timeout: self.timing.initialFrameValidationTimeout
            )
            self.mode = .initial
        }
    }

    func enterWarm(frame: CGRect) async {
        await serializeIgnoringFailure {
            self.capture.setHealthMonitoring(
                enabled: false,
                stallTimeout: self.timing.captureStallTimeout
            )
            try await self.capture.update(frame: frame, profile: .warm)
            self.mode = .warm
        }
    }

    func enterLive(
        window: CaptureWindowReference,
        frame: CGRect
    ) async throws {
        try await serialize {
            self.capture.setHealthMonitoring(
                enabled: false,
                stallTimeout: self.timing.captureStallTimeout
            )
            try await self.capture.refresh(
                window: window,
                frame: frame,
                profile: .live
            )
            self.capture.setHealthMonitoring(
                enabled: true,
                stallTimeout: self.timing.captureStallTimeout
            )
            self.mode = .live
        }
    }

    func updateGeometry(_ frame: CGRect) async throws {
        try await serialize {
            let profile: CaptureProfile =
                self.mode == .live ? .live : .warm
            try await self.capture.update(frame: frame, profile: profile)
        }
    }

    func awaitCompleteFrameAdvance(
        count: UInt64,
        timeout: Duration
    ) async -> Bool {
        await capture.awaitCompleteFrameAdvance(
            count: count,
            timeout: timeout
        )
    }

    func pausePreservingFrame() async {
        await serializeIgnoringFailure {
            self.capture.setHealthMonitoring(
                enabled: false,
                stallTimeout: self.timing.captureStallTimeout
            )
            await self.capture.stop(preserveDisplayedFrame: true)
            self.mode = .stoppedPreservingFrame
        }
    }

    func suspend() async {
        await pausePreservingFrame()
    }

    func requestStop() {
        let predecessor = operationTail
        let capture = capture
        let timing = timing
        let task = Task { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            capture.setHealthMonitoring(
                enabled: false,
                stallTimeout: timing.captureStallTimeout
            )
            await capture.stop(preserveDisplayedFrame: false)
            self?.mode = .stopped
        }
        operationTail = task
    }

    func waitUntilStopped() async {
        if let operationTail {
            await operationTail.value
        }
    }

    private func serialize(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let predecessor = operationTail
        let resultTask = Task<Void, Error> { @MainActor in
            if let predecessor {
                await predecessor.value
            }
            try await operation()
        }
        let completion = Task { @MainActor in
            _ = try? await resultTask.value
        }
        operationTail = completion
        try await resultTask.value
    }

    private func serializeIgnoringFailure(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async {
        do {
            try await serialize(operation)
        } catch is CancellationError {
            return
        } catch {
            onFailure?(error)
        }
    }
}
