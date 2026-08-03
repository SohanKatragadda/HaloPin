import XCTest
@testable import HaloPin

@MainActor
final class AppModelWarningTests: XCTestCase {
    func testWarningIndicatorCanBeAcknowledgedWithoutDiscardingWarningState() {
        let model = makeModel()

        model.showWarning("Capture paused")
        model.acknowledgeWarning()

        XCTAssertNil(model.warningIndicatorMessage)
        XCTAssertEqual(model.presentationState, .warning("Capture paused"))
    }

    func testWarningIndicatorExpiresAfterConfiguredDuration() async {
        let model = makeModel(duration: .milliseconds(20))

        model.showWarning("Capture paused")
        XCTAssertEqual(model.warningIndicatorMessage, "Capture paused")

        await waitUntil { model.warningIndicatorMessage == nil }
        XCTAssertEqual(model.presentationState, .warning("Capture paused"))
    }

    func testNewWarningRestartsIndicatorLifetime() async {
        let model = makeModel(duration: .milliseconds(60))

        model.showWarning("First")
        try? await Task.sleep(for: .milliseconds(35))
        model.showWarning("Second")
        try? await Task.sleep(for: .milliseconds(35))

        XCTAssertEqual(model.warningIndicatorMessage, "Second")
        await waitUntil { model.warningIndicatorMessage == nil }
    }

    func testLeavingWarningStateClearsIndicatorImmediately() {
        let model = makeModel()

        model.showWarning("Capture paused")
        model.presentationState = .passive

        XCTAssertNil(model.warningIndicatorMessage)
    }

    private func makeModel(duration: Duration = .seconds(600)) -> AppModel {
        let suiteName = "AppModelWarningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            defaults: defaults,
            warningIndicatorDuration: duration
        )
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
        XCTAssertTrue(condition(), "Timed out waiting for warning indicator update")
    }
}
