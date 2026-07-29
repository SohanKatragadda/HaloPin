import CoreGraphics
import Carbon
import CoreMedia
import XCTest
@testable import HaloPin

final class ModelsTests: XCTestCase {
    func testCaptureProfilesBalanceWarmEfficiencyAndLiveQuality() {
        XCTAssertEqual(CaptureProfile.warm.queueDepth, 1)
        XCTAssertEqual(CaptureProfile.live.queueDepth, 2)
        XCTAssertEqual(
            CaptureProfile.warm.minimumFrameInterval,
            CMTime(seconds: 1, preferredTimescale: 600)
        )
        XCTAssertEqual(
            CaptureProfile.live.minimumFrameInterval,
            CMTime(value: 1, timescale: 30)
        )

        XCTAssertEqual(
            CaptureProfile.live.outputPixelSize(
                for: CGSize(width: 1_200, height: 800),
                scale: 2
            ),
            CGSize(width: 2_400, height: 1_600)
        )
        XCTAssertEqual(
            CaptureProfile.warm.outputPixelSize(
                for: CGSize(width: 1_200, height: 800),
                scale: 2
            ),
            CGSize(width: 1_280, height: 853)
        )
    }

    func testPinStateHappyPath() {
        XCTAssertTrue(PinState.resolving.canTransition(to: .interactive))
        XCTAssertTrue(PinState.interactive.canTransition(to: .becomingPassive))
        XCTAssertTrue(PinState.becomingPassive.canTransition(to: .passive))
        XCTAssertTrue(PinState.passive.canTransition(to: .handingOff))
        XCTAssertTrue(PinState.handingOff.canTransition(to: .interactive))
        XCTAssertTrue(PinState.interactive.canTransition(to: .terminating))
    }

    func testPinStateRejectsInvalidTransitions() {
        XCTAssertFalse(PinState.resolving.canTransition(to: .passive))
        XCTAssertTrue(PinState.passive.canTransition(to: .interactive))
        XCTAssertFalse(PinState.terminating.canTransition(to: .interactive))
    }

    func testCompletePinStateTransitionTable() {
        let failure = PinFailure.captureFailed
        let states: [PinState] = [
            .resolving,
            .interactive,
            .becomingPassive,
            .passive,
            .handingOff,
            .terminating,
            .failed(failure)
        ]
        let allowed: Set<String> = [
            "0-1", "0-5", "0-6",
            "1-2", "1-5", "1-6",
            "2-1", "2-3", "2-5", "2-6",
            "3-1", "3-4", "3-5", "3-6",
            "4-1", "4-3", "4-5", "4-6",
            "6-5"
        ]

        for source in states.indices {
            for destination in states.indices {
                let expected = source == destination
                    || allowed.contains("\(source)-\(destination)")
                XCTAssertEqual(
                    states[source].canTransition(to: states[destination]),
                    expected,
                    "Unexpected transition \(source) -> \(destination)"
                )
            }
        }
    }

    func testCoordinateConversionRoundTrips() {
        let source = CGRect(x: -900, y: 140, width: 720, height: 480)
        let appKit = GeometryConverter.appKitRect(
            fromAX: source,
            primaryDisplayHeight: 1_080
        )
        let roundTrip = GeometryConverter.axRect(
            fromAppKit: appKit,
            primaryDisplayHeight: 1_080
        )
        XCTAssertEqual(roundTrip, source)
    }

    func testCoordinateConversionAcrossDisplayLayouts() {
        let frames = [
            CGRect(x: -1_440, y: 20, width: 1_200, height: 900),
            CGRect(x: 2_560, y: -600, width: 700, height: 1_100),
            CGRect(x: 40, y: 900, width: 1_000, height: 700)
        ]
        for frame in frames {
            let appKit = GeometryConverter.appKitRect(
                fromAX: frame,
                primaryDisplayHeight: 1_440
            )
            XCTAssertEqual(
                GeometryConverter.axRect(
                    fromAppKit: appKit,
                    primaryDisplayHeight: 1_440
                ),
                frame
            )
        }
    }

    func testCandidateMatcherUsesGeometryForDuplicateTitles() {
        let source = ResolvedWindowDescription(
            ownerPID: 42,
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let candidates = [
            WindowCandidate(
                windowID: 1,
                ownerPID: 42,
                title: "Document",
                frame: CGRect(x: 500, y: 100, width: 800, height: 600),
                zIndex: 0
            ),
            WindowCandidate(
                windowID: 2,
                ownerPID: 42,
                title: "Document",
                frame: CGRect(x: 101, y: 99, width: 800, height: 600),
                zIndex: 2
            )
        ]
        XCTAssertEqual(
            WindowCandidateMatcher.bestMatch(for: source, candidates: candidates)?.windowID,
            2
        )
    }

    func testCandidateMatcherRejectsDifferentProcess() {
        let source = ResolvedWindowDescription(
            ownerPID: 42,
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let candidate = WindowCandidate(
            windowID: 7,
            ownerPID: 43,
            title: "Document",
            frame: source.frame,
            zIndex: 0
        )
        XCTAssertNil(WindowCandidateMatcher.bestMatch(for: source, candidates: [candidate]))
    }

    func testExactWindowIdentityNeverRetargetsSimilarWindow() {
        let candidates = [
            WindowCandidate(
                windowID: 7,
                ownerPID: 42,
                title: "Document",
                frame: CGRect(x: 10, y: 10, width: 600, height: 400),
                zIndex: 0
            ),
            WindowCandidate(
                windowID: 8,
                ownerPID: 42,
                title: "Document",
                frame: CGRect(x: 10, y: 10, width: 600, height: 400),
                zIndex: 1
            ),
            WindowCandidate(
                windowID: 7,
                ownerPID: 99,
                title: "Document",
                frame: CGRect(x: 10, y: 10, width: 600, height: 400),
                zIndex: 2
            )
        ]

        XCTAssertEqual(
            WindowIdentityMatcher.exactMatch(
                windowID: 7,
                ownerPID: 42,
                candidates: candidates
            ),
            candidates[0]
        )
        XCTAssertNil(
            WindowIdentityMatcher.exactMatch(
                windowID: 9,
                ownerPID: 42,
                candidates: candidates
            )
        )
    }

    func testSourceAvailabilityIncludesStageManagerActiveWindows() {
        XCTAssertEqual(
            SourceWindowAvailability(isOnScreen: true, isActive: false),
            .available
        )
        XCTAssertEqual(
            SourceWindowAvailability(isOnScreen: false, isActive: true),
            .available
        )
        XCTAssertEqual(
            SourceWindowAvailability(isOnScreen: false, isActive: false),
            .offSpace
        )
    }

    func testDefaultShortcutIsValidAndReadable() {
        XCTAssertTrue(ShortcutDefinition.defaultShortcut.isValid)
        XCTAssertEqual(ShortcutDefinition.defaultShortcut.displayString, "⌃⌥⌘P")
    }

    func testShortcutRoundTripsThroughPersistenceFormat() throws {
        let shortcut = ShortcutDefinition(
            keyCode: 14,
            modifiers: UInt32(controlKey | optionKey)
        )
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutDefinition.self, from: data), shortcut)
    }

    func testShortcutRejectsModifierlessAndReservedCombinations() {
        XCTAssertFalse(ShortcutDefinition(keyCode: 35, modifiers: 0).isValid)
        XCTAssertFalse(
            ShortcutDefinition(keyCode: 49, modifiers: UInt32(cmdKey)).isValid
        )
        XCTAssertFalse(
            ShortcutDefinition(
                keyCode: 20,
                modifiers: UInt32(cmdKey | shiftKey)
            ).isValid
        )
        XCTAssertTrue(
            ShortcutDefinition(
                keyCode: 35,
                modifiers: UInt32(controlKey | optionKey | cmdKey)
            ).isValid
        )
    }
}
