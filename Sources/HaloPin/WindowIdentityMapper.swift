import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenCaptureWindowIdentityMapper: WindowIdentityMapping {
    func map(_ window: ResolvedWindow) async throws -> CaptureWindowReference {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )

        let candidates = content.windows.enumerated().compactMap { index, item -> WindowCandidate? in
            guard let owner = item.owningApplication else {
                return nil
            }
            return WindowCandidate(
                windowID: item.windowID,
                ownerPID: owner.processID,
                title: item.title ?? "",
                frame: item.frame,
                zIndex: index
            )
        }

        let description = ResolvedWindowDescription(
            ownerPID: window.ownerPID,
            title: window.title,
            frame: window.frame
        )
        guard let match = WindowCandidateMatcher.bestMatch(
            for: description,
            candidates: candidates
        ), let scWindow = content.windows.first(where: { $0.windowID == match.windowID }) else {
            throw PinFailure.windowMappingFailed
        }
        return CaptureWindowReference(
            scWindow,
            display: Self.containingDisplay(
                for: scWindow.frame,
                among: content.displays
            )
        )
    }

    func refresh(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) async throws -> CaptureWindowReference {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true,
                    onScreenWindowsOnly: false
                )
                let candidates = content.windows.enumerated().compactMap {
                    index, item -> WindowCandidate? in
                    guard let owner = item.owningApplication else { return nil }
                    return WindowCandidate(
                        windowID: item.windowID,
                        ownerPID: owner.processID,
                        title: item.title ?? "",
                        frame: item.frame,
                        zIndex: index
                    )
                }
                if let match = WindowIdentityMatcher.exactMatch(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    candidates: candidates
                ), let window = content.windows.first(where: {
                    $0.windowID == match.windowID
                }) {
                    return CaptureWindowReference(
                        window,
                        display: Self.containingDisplay(
                            for: window.frame,
                            among: content.displays
                        )
                    )
                }
                lastError = PinFailure.windowMappingFailed
            } catch {
                lastError = error
            }

            if attempt < 2 {
                try await Task.sleep(for: .milliseconds(180))
            }
        }
        throw lastError ?? PinFailure.windowMappingFailed
    }

    private static func containingDisplay(
        for windowFrame: CGRect,
        among displays: [SCDisplay]
    ) -> SCDisplay? {
        // Display-scoped capture cannot reconstruct the part of a window that
        // crosses onto another display. Use it only when one display contains
        // the complete window; otherwise the independent-window path remains
        // the safe fallback.
        displays.first {
            $0.frame.insetBy(dx: -1, dy: -1).contains(windowFrame)
        }
    }
}
