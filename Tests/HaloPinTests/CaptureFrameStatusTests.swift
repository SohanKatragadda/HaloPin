import ScreenCaptureKit
import XCTest
@testable import HaloPin

final class CaptureFrameStatusTests: XCTestCase {
    func testDisplayScopedCaptureUsesDisplayLocalWindowCoordinates() {
        let result = ScreenCaptureEngine.displayRelativeSourceRect(
            windowFrame: CGRect(x: 1640, y: 90, width: 640, height: 480),
            displayFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(
            result,
            CGRect(x: 128, y: 90, width: 640, height: 480)
        )
    }

    func testCompleteFramesRenderAndAdvanceFreshness() {
        XCTAssertEqual(
            ScreenCaptureEngine.disposition(for: .complete),
            .complete
        )
    }

    func testIdleAndStartedFramesOnlyMaintainHeartbeat() {
        XCTAssertEqual(
            ScreenCaptureEngine.disposition(for: .idle),
            .heartbeatOnly
        )
        XCTAssertEqual(
            ScreenCaptureEngine.disposition(for: .started),
            .heartbeatOnly
        )
    }

    func testBlankSuspendedAndStoppedFramesAreIgnored() {
        XCTAssertEqual(
            ScreenCaptureEngine.disposition(for: .blank),
            .ignored
        )
        XCTAssertEqual(
            ScreenCaptureEngine.disposition(for: .suspended),
            .ignored
        )
        XCTAssertEqual(
            ScreenCaptureEngine.disposition(for: .stopped),
            .ignored
        )
    }
}
