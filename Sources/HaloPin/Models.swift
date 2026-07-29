import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum PinState: Equatable {
    case resolving
    case interactive
    case becomingPassive
    case passive
    case handingOff
    case terminating
    case failed(PinFailure)

    func canTransition(to next: PinState) -> Bool {
        switch (self, next) {
        case (.resolving, .interactive),
             (.resolving, .failed),
             (.resolving, .terminating),
             (.interactive, .becomingPassive),
             (.interactive, .terminating),
             (.interactive, .failed),
             (.becomingPassive, .passive),
             (.becomingPassive, .interactive),
             (.becomingPassive, .terminating),
             (.becomingPassive, .failed),
             (.passive, .handingOff),
             (.passive, .interactive),
             (.passive, .terminating),
             (.passive, .failed),
             (.handingOff, .interactive),
             (.handingOff, .passive),
             (.handingOff, .terminating),
             (.handingOff, .failed),
             (.failed, .terminating):
            return true
        default:
            return self == next
        }
    }
}

enum CrossSpaceCaptureState: Equatable {
    case live
    case recovering
    case offSpaceAwaitingChoice
    case pausedOffSpace
}

enum CaptureProfile: Equatable {
    case warm
    case live

    var minimumFrameInterval: CMTime {
        switch self {
        case .warm:
            CMTime(seconds: 1, preferredTimescale: 600)
        case .live:
            CMTime(value: 1, timescale: 30)
        }
    }

    var queueDepth: Int {
        switch self {
        case .warm: 1
        case .live: 2
        }
    }

    func outputPixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        let native = CGSize(
            width: max(2, pointSize.width * scale),
            height: max(2, pointSize.height * scale)
        )
        guard self == .warm else { return native }

        let longestEdge = max(native.width, native.height)
        guard longestEdge > 1_280 else { return native }
        let reduction = 1_280 / longestEdge
        return CGSize(
            width: max(2, (native.width * reduction).rounded(.down)),
            height: max(2, (native.height * reduction).rounded(.down))
        )
    }
}

enum CaptureHealth: Equatable, Sendable {
    case healthy
    case stalled
    case stopped
}

enum CaptureLifecycleMode: Equatable {
    case stopped
    case initial
    case warm
    case live
    case stoppedPreservingFrame
}

struct SessionTiming: Equatable {
    var initialFrameValidationTimeout: Duration = .seconds(2)
    var captureRefreshFrameTimeout: Duration = .seconds(1)
    var captureConfigurationFrameWait: Duration = .milliseconds(180)
    var passiveFrameWait: Duration = .milliseconds(120)
    var geometrySettleTimeout: Duration = .milliseconds(120)
    var geometryPollInterval: Duration = .milliseconds(16)
    var interactiveGeometryDebounce: Duration = .milliseconds(80)
    var handoffPollInterval: Duration = .milliseconds(50)
    var handoffActivationTimeout: Duration = .milliseconds(2_500)
    var handoffRetryTimeout: Duration = .milliseconds(500)
    var spaceRecoveryDebounce: Duration = .milliseconds(180)
    var spaceTransitionSettleTimeout: Duration = .milliseconds(300)
    var spaceStatePollInterval: Duration = .milliseconds(25)
    var availabilityPollInterval: Duration = .milliseconds(100)
    var availabilityPollTimeout: Duration = .seconds(1)
    var windowIdentityRetryDelay: Duration = .milliseconds(180)
    var windowIdentityRetryCount = 3
    var captureStallTimeout: Duration = .milliseconds(1_500)
    var captureRecoveryCooldown: Duration = .seconds(2)

    static let production = SessionTiming()
}

enum SourceWindowAvailability: Equatable {
    case available
    case offSpace

    init(isOnScreen: Bool, isActive: Bool) {
        self = isOnScreen || isActive ? .available : .offSpace
    }
}

struct CaptureWindowReference {
    let windowID: CGWindowID
    let frame: CGRect
    let availability: SourceWindowAvailability
    let screenCaptureWindow: SCWindow?
    let screenCaptureDisplay: SCDisplay?

    init(_ window: SCWindow, display: SCDisplay? = nil) {
        windowID = window.windowID
        frame = window.frame
        availability = SourceWindowAvailability(
            isOnScreen: window.isOnScreen,
            isActive: window.isActive
        )
        screenCaptureWindow = window
        screenCaptureDisplay = display
    }

    init(
        windowID: CGWindowID,
        frame: CGRect,
        availability: SourceWindowAvailability
    ) {
        self.windowID = windowID
        self.frame = frame
        self.availability = availability
        screenCaptureWindow = nil
        screenCaptureDisplay = nil
    }
}

enum UnpinTrigger: Equatable {
    case userInitiated
    case automatic
}

struct PreviewGeometryCommit: Equatable {
    enum Kind: Equatable {
        case move
        case resize
    }

    let kind: Kind
    let frame: CGRect
}

enum PinFailure: String, Error, Equatable, LocalizedError {
    case accessibilityPermissionMissing
    case screenRecordingPermissionMissing
    case noFocusedWindow
    case unsupportedWindow
    case protectedContent
    case windowMappingFailed
    case captureFailed
    case activationFailed
    case sourceClosed
    case sourceMinimized
    case sourceHidden
    case sourceFullscreen
    case permissionRevoked

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Accessibility permission is required."
        case .screenRecordingPermissionMissing:
            "Screen Recording permission is required."
        case .noFocusedWindow:
            "No focused window is available."
        case .unsupportedWindow:
            "This window cannot be pinned."
        case .protectedContent:
            "This window contains protected content."
        case .windowMappingFailed:
            "HaloPin could not identify the focused window."
        case .captureFailed:
            "The live preview could not be started."
        case .activationFailed:
            "The original window could not be activated."
        case .sourceClosed:
            "The pinned window was closed."
        case .sourceMinimized:
            "Pinning stopped because the window was minimized."
        case .sourceHidden:
            "Pinning stopped because the application was hidden."
        case .sourceFullscreen:
            "Native fullscreen source windows are not supported."
        case .permissionRevoked:
            "A required privacy permission was revoked."
        }
    }
}

struct ResolvedWindow {
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let title: String
    let axWindow: AXUIElement
    let frame: CGRect
}

struct PinSession {
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let title: String
    let windowID: CGWindowID
    let axWindow: AXUIElement
    var sourceFrame: CGRect
    var previewFrame: CGRect
    var state: PinState
    var crossSpaceCaptureState: CrossSpaceCaptureState = .live

    var displayName: String {
        title.isEmpty ? applicationName : "\(applicationName) — \(title)"
    }
}

struct WindowCandidate: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
    let zIndex: Int
}

enum WindowIdentityMatcher {
    static func exactMatch(
        windowID: CGWindowID,
        ownerPID: pid_t,
        candidates: [WindowCandidate]
    ) -> WindowCandidate? {
        candidates.first {
            $0.windowID == windowID && $0.ownerPID == ownerPID
        }
    }
}

enum WindowCandidateMatcher {
    static func bestMatch(
        for source: ResolvedWindowDescription,
        candidates: [WindowCandidate]
    ) -> WindowCandidate? {
        var best: WindowCandidate?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidate in candidates where candidate.ownerPID == source.ownerPID {
            let geometry = geometryDelta(candidate.frame, source.frame)
            let titlePenalty: CGFloat
            if source.title.isEmpty || candidate.title.isEmpty {
                titlePenalty = 10
            } else {
                titlePenalty = source.title == candidate.title ? 0 : 1_000
            }
            let score = geometry + titlePenalty + CGFloat(candidate.zIndex) * 0.001
            if score < 1_200, score < bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }

    private static func geometryDelta(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }
}

struct ResolvedWindowDescription {
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
}

enum GeometryConverter {
    static func appKitRect(fromAX rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func axRect(fromAppKit rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    @MainActor
    static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    @MainActor
    static func appKitRect(fromAX rect: CGRect) -> CGRect {
        appKitRect(fromAX: rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    @MainActor
    static func axRect(fromAppKit rect: CGRect) -> CGRect {
        axRect(fromAppKit: rect, primaryDisplayHeight: primaryDisplayHeight)
    }
}
