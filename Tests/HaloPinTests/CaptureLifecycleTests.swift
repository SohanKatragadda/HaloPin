import AVFoundation
import XCTest
@testable import HaloPin

@MainActor
final class CaptureLifecycleTests: XCTestCase {
    func testInitialCaptureTransitionsToWarmAndThenLive() async throws {
        let capture = LifecycleMockCapture()
        let lifecycle = CaptureLifecycleCoordinator(capture: capture)
        let window = CaptureWindowReference(
            windowID: 7,
            frame: CGRect(x: 10, y: 20, width: 1_000, height: 700),
            availability: .available
        )

        try await lifecycle.prepare(window: window)
        XCTAssertEqual(lifecycle.mode, .initial)
        await lifecycle.enterWarm(frame: window.frame)
        XCTAssertEqual(lifecycle.mode, .warm)
        try await lifecycle.enterLive(window: window, frame: window.frame)
        XCTAssertEqual(lifecycle.mode, .live)

        XCTAssertEqual(capture.events, [
            "monitor:false",
            "start:live",
            "validate",
            "monitor:false",
            "update:warm",
            "monitor:false",
            "refresh:live",
            "monitor:true"
        ])
    }

    func testPausedCapturePreservesFrameAndFullStopDiscardsIt() async {
        let capture = LifecycleMockCapture()
        let lifecycle = CaptureLifecycleCoordinator(capture: capture)

        await lifecycle.pausePreservingFrame()
        XCTAssertEqual(lifecycle.mode, .stoppedPreservingFrame)
        lifecycle.requestStop()
        await lifecycle.waitUntilStopped()

        XCTAssertEqual(capture.stopPreservationValues, [true, false])
        XCTAssertEqual(lifecycle.mode, .stopped)
    }

    func testRequestedStopFinishesBeforeAQueuedNewStart() async throws {
        let capture = LifecycleMockCapture()
        let lifecycle = CaptureLifecycleCoordinator(capture: capture)
        let window = CaptureWindowReference(
            windowID: 8,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            availability: .available
        )

        lifecycle.requestStop()
        try await lifecycle.prepare(window: window)

        let stopIndex = try XCTUnwrap(
            capture.events.firstIndex(of: "stop:false")
        )
        let startIndex = try XCTUnwrap(
            capture.events.firstIndex(of: "start:live")
        )
        XCTAssertLessThan(stopIndex, startIndex)
    }
}

@MainActor
private final class LifecycleMockCapture: CaptureStreaming {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onHealthChanged: ((CaptureHealth) -> Void)?
    var onFailure: ((Error) -> Void)?
    var events: [String] = []
    var stopPreservationValues: [Bool] = []

    func start(
        window: CaptureWindowReference,
        profile: CaptureProfile
    ) async throws {
        events.append("start:\(profile)")
    }

    func refresh(
        window: CaptureWindowReference,
        frame: CGRect,
        profile: CaptureProfile
    ) async throws {
        events.append("refresh:\(profile)")
    }

    func update(frame: CGRect, profile: CaptureProfile) async throws {
        events.append("update:\(profile)")
    }

    func awaitCompleteFrameAdvance(
        count: UInt64,
        timeout: Duration
    ) async -> Bool {
        true
    }

    func validateInitialFrame(timeout: Duration) async throws {
        events.append("validate")
    }

    func setHealthMonitoring(enabled: Bool, stallTimeout: Duration) {
        events.append("monitor:\(enabled)")
    }

    func stop(preserveDisplayedFrame: Bool) async {
        events.append("stop:\(preserveDisplayedFrame)")
        stopPreservationValues.append(preserveDisplayedFrame)
    }
}
