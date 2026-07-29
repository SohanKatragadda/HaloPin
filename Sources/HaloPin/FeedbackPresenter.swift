import AppKit
import Foundation
import QuartzCore

@MainActor
final class FeedbackPresenter: FeedbackPresenting {
    private var pinSound: NSSound?
    private var unpinSound: NSSound?

    func presentPinFeedback(around axFrame: CGRect, halo: Bool, sound: Bool) {
        if halo {
            HaloWindowPresenter.present(around: axFrame)
        }
        if sound {
            playPinSound()
        }
        NSAccessibility.post(
            element: NSApp!,
            notification: .announcementRequested,
            userInfo: [.announcement: "Window pinned", .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    func showHUD(_ message: String) {
        HUDPresenter.present(message)
    }

    func presentUnpinFeedback(sound: Bool) {
        if sound {
            playUnpinSound()
        }
        NSAccessibility.post(
            element: NSApp!,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Window unpinned",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func playPinSound() {
        let data = SynthesizedSound.pinConfirmationWAV()
        pinSound = NSSound(data: data)
        pinSound?.volume = 0.45
        pinSound?.play()
    }

    private func playUnpinSound() {
        let data = SynthesizedSound.unpinConfirmationWAV()
        unpinSound = NSSound(data: data)
        unpinSound?.volume = 0.32
        unpinSound?.play()
    }
}

@MainActor
private enum HaloWindowPresenter {
    static func present(around axFrame: CGRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let inset: CGFloat = 8
        let frame = GeometryConverter.appKitRect(fromAX: axFrame).insetBy(dx: -inset, dy: -inset)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let view = NSView(frame: panel.contentView?.bounds ?? .zero)
        view.wantsLayer = true
        view.layer?.borderWidth = 4
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.cornerRadius = 12
        view.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        view.layer?.shadowOpacity = 0.9
        view.layer?.shadowRadius = 12
        panel.contentView = view
        panel.orderFrontRegardless()

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        opacity.duration = 0.6
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.duration = 0.6
        group.animations = [opacity]
        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.98
            scale.toValue = 1.08
            scale.duration = 0.6
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.animations?.append(scale)
        }
        view.layer?.add(group, forKey: "pinHalo")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            panel.orderOut(nil)
            panel.close()
        }
    }
}

@MainActor
private enum HUDPresenter {
    static func present(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12)
        ])

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = effect
        panel.center()
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            panel.orderOut(nil)
            panel.close()
        }
    }
}

private enum SynthesizedSound {
    static func pinConfirmationWAV() -> Data {
        let sampleRate = 22_050
        let duration = 0.19
        let sampleCount = Int(Double(sampleRate) * duration)
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let frequency = t < 0.085 ? 660.0 : 880.0
            let envelope = min(1, t / 0.012) * max(0, 1 - t / duration)
            let value = sin(2 * .pi * frequency * t) * envelope * 0.28
            samples.append(Int16(value * Double(Int16.max)))
        }

        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(UInt32(36 + samples.count * 2))
        data.appendASCII("WAVEfmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(sampleRate * 2))
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(UInt32(samples.count * 2))
        for sample in samples {
            data.appendUInt16LE(UInt16(bitPattern: sample))
        }
        return data
    }

    static func unpinConfirmationWAV() -> Data {
        let sampleRate = 22_050
        let duration = 0.16
        let sampleCount = Int(Double(sampleRate) * duration)
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let frequency = t < 0.07 ? 520.0 : 390.0
            let envelope = min(1, t / 0.01) * max(0, 1 - t / duration)
            let value = sin(2 * .pi * frequency * t) * envelope * 0.22
            samples.append(Int16(value * Double(Int16.max)))
        }

        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(UInt32(36 + samples.count * 2))
        data.appendASCII("WAVEfmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(sampleRate * 2))
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(UInt32(samples.count * 2))
        for sample in samples {
            data.appendUInt16LE(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii) ?? Data())
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
