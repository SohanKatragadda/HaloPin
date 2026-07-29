import AppKit
import QuartzCore

@MainActor
final class PreviewPanelController: NSObject, PreviewPresenting, NSWindowDelegate {
    var onActivate: (() -> Void)?
    var onFrameChanged: ((CGRect) -> Void)?
    var onGeometryCommitted: ((PreviewGeometryCommit) -> Void)?
    var onAllDesktopsConfirmed: (() -> Void)?
    var onAllDesktopsDeclined: (() -> Void)?

    private var panel: PassivePreviewPanel?
    private var content: PreviewContentView?
    private var suppressFrameCallback = false
    private var isUserLiveResizing = false

    var previewFrame: CGRect? {
        guard let frame = panel?.frame else { return nil }
        return GeometryConverter.axRect(fromAppKit: frame)
    }

    func configure(displayLayer: CALayer, frame: CGRect, aspectRatio: CGSize) {
        tearDown()

        let content = PreviewContentView(frame: .zero)
        content.attach(displayLayer: displayLayer)
        content.onActivate = { [weak self] in self?.onActivate?() }
        content.onMoveCommitted = { [weak self] in
            self?.reportGeometryCommit(kind: .move)
        }
        content.onAllDesktopsConfirmed = { [weak self] in
            self?.onAllDesktopsConfirmed?()
        }
        content.onAllDesktopsDeclined = { [weak self] in
            self?.onAllDesktopsDeclined?()
        }

        let panel = PassivePreviewPanel(
            contentRect: GeometryConverter.appKitRect(fromAX: frame),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        // A borderless panel does not receive AppKit's standard window mask.
        // Keep the window itself transparent and let PreviewContentView apply a
        // consistent macOS-style continuous corner to the captured content.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.title = "HaloPin Preview"
        panel.contentAspectRatio = aspectRatio
        panel.minSize = CGSize(width: 160, height: max(100, 160 * aspectRatio.height / aspectRatio.width))
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityLabel("Pinned window preview")

        self.content = content
        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        guard !panel.isVisible else {
            panel.alphaValue = 1
            content?.isFrozen = false
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        content?.isFrozen = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
        content?.isFrozen = false
    }

    func freeze() {
        panel?.ignoresMouseEvents = true
        content?.isFrozen = true
    }

    func setPaused(_ paused: Bool) {
        content?.isPaused = paused
    }

    func setCrossSpaceState(
        _ state: CrossSpaceCaptureState,
        applicationName: String
    ) {
        content?.setCrossSpaceState(state, applicationName: applicationName)
    }

    func updateSourceGeometry(_ frame: CGRect) {
        panel?.contentAspectRatio = frame.size
        panel?.minSize = CGSize(
            width: 160,
            height: max(100, 160 * frame.height / frame.width)
        )
    }

    func animate(to frame: CGRect) {
        guard let panel else { return }
        suppressFrameCallback = true
        let appKitFrame = GeometryConverter.appKitRect(fromAX: frame)
        guard panel.isVisible else {
            panel.setFrame(appKitFrame, display: true)
            suppressFrameCallback = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(appKitFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.suppressFrameCallback = false
            }
        }
    }

    func fadeOut(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let panel else {
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                self?.content?.isFrozen = false
                completion()
            }
        }
    }

    func tearDown() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        content = nil
    }

    func clampToVisibleScreens() {
        guard let panel, !NSScreen.screens.isEmpty else { return }
        let destination = NSScreen.screens.min { lhs, rhs in
            lhs.visibleFrame.distance(to: panel.frame.center)
                < rhs.visibleFrame.distance(to: panel.frame.center)
        }?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, destination.width)
        frame.size.height = min(frame.height, destination.height)
        frame.origin.x = min(
            max(frame.origin.x, destination.minX),
            destination.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.origin.y, destination.minY),
            destination.maxY - frame.height
        )
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    func windowDidMove(_ notification: Notification) {
        reportFrameChange()
    }

    func windowDidResize(_ notification: Notification) {
        reportFrameChange()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard !suppressFrameCallback else { return }
        isUserLiveResizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard isUserLiveResizing else { return }
        isUserLiveResizing = false
        reportFrameChange()
        reportGeometryCommit(kind: .resize)
    }

    private func reportFrameChange() {
        guard !suppressFrameCallback, let previewFrame else { return }
        onFrameChanged?(previewFrame)
    }

    private func reportGeometryCommit(kind: PreviewGeometryCommit.Kind) {
        guard !suppressFrameCallback, let previewFrame else { return }
        onGeometryCommitted?(PreviewGeometryCommit(kind: kind, frame: previewFrame))
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}

private final class PassivePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PreviewContentView: NSView {
    private static let windowCornerRadius: CGFloat = 12

    var onActivate: (() -> Void)?
    var onMoveCommitted: (() -> Void)?
    var onAllDesktopsConfirmed: (() -> Void)?
    var onAllDesktopsDeclined: (() -> Void)?

    var isFrozen = false {
        didSet {
            guard isFrozen != oldValue else { return }
            updateOverlay()
        }
    }

    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            updateOverlay()
        }
    }

    private var crossSpaceState: CrossSpaceCaptureState = .live {
        didSet {
            guard crossSpaceState != oldValue else { return }
            updateOverlay()
        }
    }

    private weak var displayLayer: CALayer?
    private let dragHandle = CAShapeLayer()
    private let pausedBadge = CATextLayer()
    private let frozenLayer = CALayer()
    private let offSpaceDimLayer = CALayer()
    private let guidanceView = NSVisualEffectView()
    private let guidanceLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = Self.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.allowsEdgeAntialiasing = true

        offSpaceDimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        offSpaceDimLayer.isHidden = true
        layer?.addSublayer(offSpaceDimLayer)

        dragHandle.fillColor = NSColor.white.withAlphaComponent(0.85).cgColor
        dragHandle.shadowColor = NSColor.black.cgColor
        dragHandle.shadowOpacity = 0.3
        dragHandle.shadowRadius = 2
        layer?.addSublayer(dragHandle)

        pausedBadge.string = "  PAUSED  "
        pausedBadge.fontSize = 11
        pausedBadge.alignmentMode = .center
        pausedBadge.foregroundColor = NSColor.white.cgColor
        pausedBadge.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        pausedBadge.cornerRadius = 7
        pausedBadge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        pausedBadge.isHidden = true
        layer?.addSublayer(pausedBadge)

        frozenLayer.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        frozenLayer.isHidden = true
        layer?.addSublayer(frozenLayer)

        configureGuidanceView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(displayLayer: CALayer) {
        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = displayLayer
        layer?.insertSublayer(displayLayer, at: 0)
        needsLayout = true
    }

    func setCrossSpaceState(
        _ state: CrossSpaceCaptureState,
        applicationName: String
    ) {
        crossSpaceState = state
        guidanceLabel.stringValue =
            """
            To keep \(applicationName) live, right-click it in the Dock:
            Options → Assign To → All Desktops.
            This affects the entire app.
            """
    }

    override func layout() {
        super.layout()
        displayLayer?.frame = bounds
        frozenLayer.frame = bounds
        offSpaceDimLayer.frame = bounds

        let handleWidth: CGFloat = 48
        let handleHeight: CGFloat = 7
        let handleRect = CGRect(
            x: bounds.midX - handleWidth / 2,
            y: bounds.maxY - 15,
            width: handleWidth,
            height: handleHeight
        )
        dragHandle.path = CGPath(
            roundedRect: handleRect,
            cornerWidth: handleHeight / 2,
            cornerHeight: handleHeight / 2,
            transform: nil
        )
        pausedBadge.frame = CGRect(
            x: bounds.midX - 85,
            y: bounds.midY - 12,
            width: 170,
            height: 24
        )
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if location.y >= bounds.maxY - 24 {
            window?.performDrag(with: event)
            onMoveCommitted?()
        } else {
            onActivate?()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            CGRect(x: 0, y: max(0, bounds.maxY - 24), width: bounds.width, height: 24),
            cursor: .openHand
        )
        addCursorRect(
            CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 24)),
            cursor: .pointingHand
        )
    }

    private func updateOverlay() {
        switch crossSpaceState {
        case .live:
            guidanceView.isHidden = true
            offSpaceDimLayer.isHidden = true
            pausedBadge.string = "  PAUSED  "
            pausedBadge.isHidden = !isPaused
        case .recovering:
            guidanceView.isHidden = true
            offSpaceDimLayer.isHidden = true
            pausedBadge.string = "  RECOVERING…  "
            pausedBadge.isHidden = false
        case .offSpaceAwaitingChoice:
            guidanceView.isHidden = false
            offSpaceDimLayer.isHidden = false
            pausedBadge.isHidden = true
        case .pausedOffSpace:
            guidanceView.isHidden = true
            offSpaceDimLayer.isHidden = false
            pausedBadge.string = "  OFF DESKTOP — PAUSED  "
            pausedBadge.isHidden = false
        }
        frozenLayer.isHidden = !isFrozen
    }

    private func configureGuidanceView() {
        guidanceView.material = .hudWindow
        guidanceView.blendingMode = .withinWindow
        guidanceView.state = .active
        guidanceView.wantsLayer = true
        guidanceView.layer?.cornerRadius = 12
        guidanceView.translatesAutoresizingMaskIntoConstraints = false
        guidanceView.isHidden = true

        guidanceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        guidanceLabel.textColor = .labelColor
        guidanceLabel.alignment = .center
        guidanceLabel.maximumNumberOfLines = 6

        let confirmedButton = NSButton(
            title: "I’ve Assigned It",
            target: self,
            action: #selector(confirmAllDesktops)
        )
        confirmedButton.bezelStyle = .rounded
        confirmedButton.controlSize = .small
        confirmedButton.setAccessibilityLabel(
            "Confirm assignment to All Desktops"
        )

        let declineButton = NSButton(
            title: "Not Now",
            target: self,
            action: #selector(declineAllDesktops)
        )
        declineButton.bezelStyle = .rounded
        declineButton.controlSize = .small

        let buttons = NSStackView(views: [confirmedButton, declineButton])
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 4
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [guidanceLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        guidanceView.addSubview(stack)
        addSubview(guidanceView)
        NSLayoutConstraint.activate([
            guidanceView.centerXAnchor.constraint(equalTo: centerXAnchor),
            guidanceView.centerYAnchor.constraint(equalTo: centerYAnchor),
            guidanceView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 6
            ),
            guidanceView.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -6
            ),
            guidanceView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            stack.leadingAnchor.constraint(
                equalTo: guidanceView.leadingAnchor,
                constant: 8
            ),
            stack.trailingAnchor.constraint(
                equalTo: guidanceView.trailingAnchor,
                constant: -8
            ),
            stack.topAnchor.constraint(
                equalTo: guidanceView.topAnchor,
                constant: 6
            ),
            stack.bottomAnchor.constraint(
                equalTo: guidanceView.bottomAnchor,
                constant: -6
            )
        ])
    }

    @objc private func confirmAllDesktops() {
        onAllDesktopsConfirmed?()
    }

    @objc private func declineAllDesktops() {
        onAllDesktopsDeclined?()
    }
}
