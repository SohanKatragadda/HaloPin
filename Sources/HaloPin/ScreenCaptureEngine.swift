import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

final class ScreenCaptureEngine:
    NSObject,
    CaptureStreaming,
    SCStreamDelegate,
    SCStreamOutput,
    @unchecked Sendable
{
    nonisolated(unsafe) let displayLayer = AVSampleBufferDisplayLayer()

    private let outputQueue = DispatchQueue(
        label: "com.halopin.capture.frames",
        qos: .userInitiated
    )
    private let activity = CaptureActivityTracker()
    private let timing: SessionTiming

    @MainActor private var stream: SCStream?
    @MainActor private var healthTask: Task<Void, Never>?
    @MainActor private var configuredPixelSize: CGSize?
    @MainActor private var configuredSourceRect: CGRect?
    @MainActor private var configuredProfile: CaptureProfile?
    @MainActor private var captureDisplayFrame: CGRect?

    @MainActor var onHealthChanged: ((CaptureHealth) -> Void)?
    @MainActor var onFailure: ((Error) -> Void)?

    init(timing: SessionTiming = .production) {
        self.timing = timing
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
    }

    @MainActor
    func start(
        window: CaptureWindowReference,
        profile: CaptureProfile
    ) async throws {
        await stop(preserveDisplayedFrame: false)
        guard let screenCaptureWindow = window.screenCaptureWindow else {
            throw PinFailure.windowMappingFailed
        }
        try await installStream(
            window: screenCaptureWindow,
            frame: window.frame,
            display: nil,
            profile: profile
        )
    }

    @MainActor
    func refresh(
        window: CaptureWindowReference,
        frame: CGRect,
        profile: CaptureProfile
    ) async throws {
        guard let screenCaptureWindow = window.screenCaptureWindow else {
            throw PinFailure.windowMappingFailed
        }
        try await restartPreservingDisplayedFrame(
            window: screenCaptureWindow,
            frame: frame,
            display: window.screenCaptureDisplay,
            profile: profile
        )
        let snapshot = activity.snapshot()
        guard await activity.waitForAdvance(
            after: snapshot.generationStartSequence,
            generation: snapshot.generation,
            count: 1,
            timeout: timing.captureRefreshFrameTimeout
        ) else {
            throw PinFailure.captureFailed
        }
    }

    @MainActor
    func update(frame: CGRect, profile: CaptureProfile) async throws {
        guard let stream else { return }
        let baseline = activity.snapshot()
        let changed = try await updateConfigurationIfNeeded(
            stream: stream,
            frame: frame,
            profile: profile
        )
        if changed, profile == .live {
            _ = await activity.waitForAdvance(
                after: baseline.sequence,
                generation: baseline.generation,
                count: 1,
                timeout: timing.captureConfigurationFrameWait
            )
        }
    }

    @MainActor
    func awaitCompleteFrameAdvance(
        count: UInt64,
        timeout: Duration
    ) async -> Bool {
        let baseline = activity.snapshot()
        return await activity.waitForAdvance(
            after: baseline.sequence,
            generation: baseline.generation,
            count: count,
            timeout: timeout
        )
    }

    @MainActor
    func validateInitialFrame(timeout: Duration = .seconds(2)) async throws {
        let snapshot = activity.snapshot()
        let receivedFrame = await activity.waitForAdvance(
            after: snapshot.generationStartSequence,
            generation: snapshot.generation,
            count: 1,
            timeout: timeout
        )
        if displayLayer.isOutputObscuredDueToInsufficientExternalProtection {
            throw PinFailure.protectedContent
        }
        guard receivedFrame else {
            throw PinFailure.captureFailed
        }
    }

    @MainActor
    func setHealthMonitoring(enabled: Bool, stallTimeout: Duration) {
        healthTask?.cancel()
        healthTask = nil
        if let transition = activity.setMonitoring(enabled: enabled) {
            onHealthChanged?(transition)
        }
        guard enabled else { return }

        let activity = activity
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let remaining = activity.remainingUntilStall(
                    timeout: stallTimeout
                ) else {
                    return
                }
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                    if Task.isCancelled { return }
                }
                if let transition = activity.markStalledIfNeeded(
                    timeout: stallTimeout
                ) {
                    self?.onHealthChanged?(transition)
                } else if remaining == .zero {
                    try? await Task.sleep(for: stallTimeout)
                }
            }
        }
    }

    @MainActor
    func stop(preserveDisplayedFrame: Bool) async {
        healthTask?.cancel()
        healthTask = nil
        if let transition = activity.invalidate() {
            onHealthChanged?(transition)
        }

        let previousStream = stream
        stream = nil
        configuredPixelSize = nil
        configuredSourceRect = nil
        configuredProfile = nil
        captureDisplayFrame = nil
        if let previousStream {
            try? await previousStream.stopCapture()
        }
        await displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: !preserveDisplayedFrame
        )
    }

    @MainActor
    private func installStream(
        window: SCWindow,
        frame: CGRect,
        display: SCDisplay?,
        profile: CaptureProfile
    ) async throws {
        let filter: SCContentFilter
        if let display {
            filter = SCContentFilter(display: display, including: [window])
            captureDisplayFrame = display.frame
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureDisplayFrame = nil
        }
        let configuration = Self.configuration(
            for: frame,
            displayFrame: captureDisplayFrame,
            profile: profile
        )
        configuredPixelSize = CGSize(
            width: configuration.width,
            height: configuration.height
        )
        configuredSourceRect = captureDisplayFrame.map {
            Self.displayRelativeSourceRect(
                windowFrame: frame,
                displayFrame: $0
            )
        }
        configuredProfile = profile

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try newStream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: outputQueue
        )
        activity.begin(streamID: ObjectIdentifier(newStream))
        stream = newStream
        do {
            try await newStream.startCapture()
        } catch {
            if stream === newStream {
                stream = nil
                configuredPixelSize = nil
                configuredSourceRect = nil
                configuredProfile = nil
                captureDisplayFrame = nil
                _ = activity.invalidate()
            }
            throw error
        }
    }

    @MainActor
    private func restartPreservingDisplayedFrame(
        window: SCWindow,
        frame: CGRect,
        display: SCDisplay?,
        profile: CaptureProfile
    ) async throws {
        let previousStream = stream
        stream = nil
        configuredPixelSize = nil
        configuredSourceRect = nil
        configuredProfile = nil
        captureDisplayFrame = nil
        _ = activity.invalidate()
        if let previousStream {
            try? await previousStream.stopCapture()
        }
        await displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: false
        )
        try await installStream(
            window: window,
            frame: frame,
            display: display,
            profile: profile
        )
    }

    @MainActor
    private func updateConfigurationIfNeeded(
        stream: SCStream,
        frame: CGRect,
        profile: CaptureProfile
    ) async throws -> Bool {
        let configuration = Self.configuration(
            for: frame,
            displayFrame: captureDisplayFrame,
            profile: profile
        )
        let requestedPixelSize = CGSize(
            width: configuration.width,
            height: configuration.height
        )
        let requestedSourceRect = captureDisplayFrame.map {
            Self.displayRelativeSourceRect(
                windowFrame: frame,
                displayFrame: $0
            )
        }
        guard requestedPixelSize != configuredPixelSize
                || requestedSourceRect != configuredSourceRect
                || profile != configuredProfile else {
            return false
        }
        try await stream.updateConfiguration(configuration)
        configuredPixelSize = requestedPixelSize
        configuredSourceRect = requestedSourceRect
        configuredProfile = profile
        return true
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
           let statusNumber = attachments.first?[.status] as? NSNumber,
           let status = SCFrameStatus(rawValue: statusNumber.intValue) else {
            return
        }

        let disposition = Self.disposition(for: status)
        if disposition == .complete {
            Self.markForImmediateDisplay(sampleBuffer)
        }
        let streamID = ObjectIdentifier(stream)
        let transition = activity.process(
            streamID: streamID,
            disposition: disposition
        ) {
            if disposition == .complete {
                displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            }
        }
        if let transition {
            Task { @MainActor [weak self] in
                guard self?.activity.isCurrent(streamID: streamID) == true else {
                    return
                }
                self?.onHealthChanged?(transition)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        guard activity.isCurrent(streamID: streamID) else { return }
        Task { @MainActor [weak self] in
            guard self?.activity.isCurrent(streamID: streamID) == true else {
                return
            }
            self?.onFailure?(error)
        }
    }

    nonisolated static func disposition(
        for status: SCFrameStatus
    ) -> CaptureFrameDisposition {
        switch status {
        case .complete:
            .complete
        case .idle, .started:
            .heartbeatOnly
        case .blank, .suspended, .stopped:
            .ignored
        @unknown default:
            .ignored
        }
    }

    nonisolated private static func markForImmediateDisplay(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0,
        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) else {
            return
        }

        let dictionary = unsafeBitCast(
            rawDictionary,
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(
                kCMSampleAttachmentKey_DisplayImmediately
            ).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    @MainActor
    private static func backingScale(for axFrame: CGRect) -> CGFloat {
        let appKitFrame = GeometryConverter.appKitRect(fromAX: axFrame)
        return NSScreen.screens.first(where: { $0.frame.intersects(appKitFrame) })?
            .backingScaleFactor ?? 2
    }

    nonisolated static func displayRelativeSourceRect(
        windowFrame: CGRect,
        displayFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: windowFrame.minX - displayFrame.minX,
            y: windowFrame.minY - displayFrame.minY,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    @MainActor
    private static func configuration(
        for frame: CGRect,
        displayFrame: CGRect?,
        profile: CaptureProfile
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = profile.minimumFrameInterval
        configuration.queueDepth = profile.queueDepth
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if let displayFrame {
            configuration.sourceRect = displayRelativeSourceRect(
                windowFrame: frame,
                displayFrame: displayFrame
            )
        }

        let pixelSize = profile.outputPixelSize(
            for: frame.size,
            scale: backingScale(for: frame)
        )
        configuration.width = max(2, Int(pixelSize.width))
        configuration.height = max(2, Int(pixelSize.height))
        return configuration
    }
}

enum CaptureFrameDisposition: Equatable {
    case complete
    case heartbeatOnly
    case ignored
}
