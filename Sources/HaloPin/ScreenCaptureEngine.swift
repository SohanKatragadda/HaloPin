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
        qos: .userInteractive
    )
    nonisolated(unsafe) private var stream: SCStream?
    @MainActor private var hasReceivedCompleteFrame = false
    @MainActor private var completeFrameSequence: UInt64 = 0
    @MainActor private var configuredPixelSize: CGSize?
    @MainActor private var configuredSourceRect: CGRect?
    @MainActor private var captureDisplayFrame: CGRect?

    @MainActor var onSampleHeartbeat: (() -> Void)?
    @MainActor var onCompleteFrame: (() -> Void)?
    @MainActor var onFailure: ((Error) -> Void)?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
    }

    @MainActor
    func start(window: CaptureWindowReference) async throws {
        await stop()
        hasReceivedCompleteFrame = false
        guard let screenCaptureWindow = window.screenCaptureWindow else {
            throw PinFailure.windowMappingFailed
        }
        try await installStream(
            window: screenCaptureWindow,
            frame: window.frame,
            display: nil
        )
    }

    @MainActor
    func refresh(window: CaptureWindowReference, frame: CGRect) async throws {
        guard let screenCaptureWindow = window.screenCaptureWindow else {
            throw PinFailure.windowMappingFailed
        }
        // A stream may keep producing nominally complete frames while its
        // desktop-independent window remains bound to an old Space surface.
        // Recreate the stream on every explicit rebind instead of treating
        // frame count alone as proof that the source surface is current.
        let baseline = completeFrameSequence
        try await restartPreservingDisplayedFrame(
            window: screenCaptureWindow,
            frame: frame,
            display: window.screenCaptureDisplay
        )
        guard await waitForCompleteFrames(
            after: baseline,
            count: 1,
            timeout: .seconds(1)
        ) else {
            throw PinFailure.captureFailed
        }
    }

    @MainActor
    func resize(to frame: CGRect) async throws {
        guard let stream else { return }
        let baseline = completeFrameSequence
        let changed = try await updateConfigurationIfNeeded(stream: stream, frame: frame)
        if changed {
            _ = await waitForCompleteFrames(
                after: baseline,
                count: 1,
                timeout: .milliseconds(180)
            )
        }
    }

    @MainActor
    func awaitCompleteFrameAdvance(count: UInt64, timeout: Duration) async -> Bool {
        await waitForCompleteFrames(
            after: completeFrameSequence,
            count: count,
            timeout: timeout
        )
    }

    @MainActor
    func validateInitialFrame(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if displayLayer.isOutputObscuredDueToInsufficientExternalProtection {
                throw PinFailure.protectedContent
            }
            if hasReceivedCompleteFrame {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PinFailure.captureFailed
    }

    @MainActor
    func stop() async {
        guard let stream else {
            await displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
            configuredPixelSize = nil
            configuredSourceRect = nil
            captureDisplayFrame = nil
            return
        }
        self.stream = nil
        configuredPixelSize = nil
        configuredSourceRect = nil
        captureDisplayFrame = nil
        do {
            try await stream.stopCapture()
        } catch {
            // Cleanup must be idempotent; the stream may already have stopped.
        }
        await displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    @MainActor
    private func installStream(
        window: SCWindow,
        frame: CGRect,
        display: SCDisplay?
    ) async throws {
        let filter: SCContentFilter
        if let display {
            // A desktop-independent filter can remain connected to the
            // original Space's backing surface even after an All Desktops
            // window appears elsewhere. A display-scoped single-window filter
            // instead binds to the composited instance on the current Space.
            filter = SCContentFilter(display: display, including: [window])
            captureDisplayFrame = display.frame
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureDisplayFrame = nil
        }
        let configuration = Self.configuration(
            for: frame,
            displayFrame: captureDisplayFrame
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
        stream = newStream
        do {
            try await newStream.startCapture()
        } catch {
            if stream === newStream {
                stream = nil
                configuredPixelSize = nil
            }
            throw error
        }
    }

    @MainActor
    private func restartPreservingDisplayedFrame(
        window: SCWindow,
        frame: CGRect,
        display: SCDisplay?
    ) async throws {
        let previousStream = stream
        stream = nil
        configuredPixelSize = nil
        configuredSourceRect = nil
        captureDisplayFrame = nil
        hasReceivedCompleteFrame = false
        if let previousStream {
            try? await previousStream.stopCapture()
        }
        // A replacement SCStream may start its presentation timeline before the
        // previous stream's final timestamp. Reset the renderer queue/timing
        // state while retaining the last displayed image during recovery.
        await displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: false
        )
        try await installStream(window: window, frame: frame, display: display)
    }

    @MainActor
    private func updateConfigurationIfNeeded(
        stream: SCStream,
        frame: CGRect
    ) async throws -> Bool {
        let configuration = Self.configuration(
            for: frame,
            displayFrame: captureDisplayFrame
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
                || requestedSourceRect != configuredSourceRect else {
            return false
        }
        try await stream.updateConfiguration(configuration)
        configuredPixelSize = requestedPixelSize
        configuredSourceRect = requestedSourceRect
        return true
    }

    @MainActor
    private func waitForCompleteFrames(
        after baseline: UInt64,
        count: UInt64,
        timeout: Duration
    ) async -> Bool {
        let targetSequence = baseline &+ count
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while completeFrameSequence < targetSequence, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(8))
            if Task.isCancelled { return false }
        }
        return completeFrameSequence >= targetSequence
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

        guard stream === self.stream else { return }
        let disposition = Self.disposition(for: status)
        if disposition == .complete {
            Self.markForImmediateDisplay(sampleBuffer)
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }

        Task { @MainActor [weak self] in
            guard let self, stream === self.stream else { return }
            switch disposition {
            case .complete:
                self.onSampleHeartbeat?()
                self.completeFrameSequence &+= 1
                self.hasReceivedCompleteFrame = true
                self.onCompleteFrame?()
            case .heartbeatOnly:
                self.onSampleHeartbeat?()
            case .ignored:
                break
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, stream === self.stream else { return }
            self.onFailure?(error)
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
        displayFrame: CGRect?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if let displayFrame {
            configuration.sourceRect = displayRelativeSourceRect(
                windowFrame: frame,
                displayFrame: displayFrame
            )
        }

        let scale = backingScale(for: frame)
        configuration.width = max(2, Int(frame.width * scale))
        configuration.height = max(2, Int(frame.height * scale))
        return configuration
    }
}

enum CaptureFrameDisposition: Equatable {
    case complete
    case heartbeatOnly
    case ignored
}
