import Foundation
import XCTest
@testable import HaloPin

final class CaptureActivityTrackerTests: XCTestCase {
    func testHealthTransitionsAreCoalescedInsteadOfEmittedPerFrame() async {
        let tracker = CaptureActivityTracker()
        let stream = NSObject()
        let streamID = ObjectIdentifier(stream)
        tracker.begin(streamID: streamID)
        XCTAssertNil(tracker.setMonitoring(enabled: true))

        XCTAssertEqual(
            tracker.process(
                streamID: streamID,
                disposition: .complete,
                render: {}
            ),
            .healthy
        )
        for _ in 0..<100 {
            XCTAssertNil(
                tracker.process(
                    streamID: streamID,
                    disposition: .complete,
                    render: {}
                )
            )
        }

        try? await Task.sleep(for: .milliseconds(8))
        XCTAssertEqual(
            tracker.markStalledIfNeeded(timeout: .milliseconds(5)),
            .stalled
        )
        XCTAssertNil(
            tracker.markStalledIfNeeded(timeout: .milliseconds(5))
        )
        XCTAssertEqual(
            tracker.process(
                streamID: streamID,
                disposition: .heartbeatOnly,
                render: {}
            ),
            .healthy
        )
    }

    func testCompleteFrameWaitUsesSignalInsteadOfPolling() async {
        let tracker = CaptureActivityTracker()
        let stream = NSObject()
        let streamID = ObjectIdentifier(stream)
        tracker.begin(streamID: streamID)
        let baseline = tracker.snapshot()

        let waiter = Task {
            await tracker.waitForAdvance(
                after: baseline.sequence,
                generation: baseline.generation,
                count: 1,
                timeout: .seconds(1)
            )
        }
        await Task.yield()
        _ = tracker.process(
            streamID: streamID,
            disposition: .complete,
            render: {}
        )

        let didAdvance = await waiter.value
        XCTAssertTrue(didAdvance)
    }

    func testWaitTimesOutAndStreamReplacementCancelsOldWaiters() async {
        let tracker = CaptureActivityTracker()
        let first = NSObject()
        tracker.begin(streamID: ObjectIdentifier(first))
        let baseline = tracker.snapshot()

        let didAdvanceBeforeTimeout = await tracker.waitForAdvance(
            after: baseline.sequence,
            generation: baseline.generation,
            count: 1,
            timeout: .milliseconds(5)
        )
        XCTAssertFalse(didAdvanceBeforeTimeout)

        let waiter = Task {
            await tracker.waitForAdvance(
                after: baseline.sequence,
                generation: baseline.generation,
                count: 1,
                timeout: .seconds(1)
            )
        }
        await Task.yield()
        let second = NSObject()
        tracker.begin(streamID: ObjectIdentifier(second))
        let didAdvanceAfterReplacement = await waiter.value
        XCTAssertFalse(didAdvanceAfterReplacement)
    }
}
