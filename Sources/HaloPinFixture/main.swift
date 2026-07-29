import AppKit
import WebKit

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        createStandardWindow(title: "Standard Fixture", origin: CGPoint(x: 120, y: 520))
        createStandardWindow(title: "Duplicate Title", origin: CGPoint(x: 600, y: 520))
        createStandardWindow(title: "Duplicate Title", origin: CGPoint(x: 600, y: 180))
        createFixedWindow()
        createWebWindow()
        NSApp.activate()
    }

    private func createStandardWindow(title: String, origin: CGPoint) {
        let frame = CGRect(origin: origin, size: CGSize(width: 420, height: 260))
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = CGSize(width: 280, height: 180)
        window.contentViewController = NSHostingFixtureViewController(title: title)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    private func createFixedWindow() {
        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 170, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fixed Size Fixture"
        window.contentViewController = NSHostingFixtureViewController(title: window.title)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    private func createWebWindow() {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <style>
              body { font: 18px -apple-system; padding: 24px; color: #eee; background: #273043; }
              input { font-size: 18px; width: 90%; padding: 8px; }
            </style>
            <h2>Web Fixture</h2>
            <p>This verifies live capture and native text input after handoff.</p>
            <input placeholder="Type here after activation">
            """,
            baseURL: nil
        )
        let window = NSWindow(
            contentRect: CGRect(x: 1_050, y: 300, width: 440, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Web Fixture"
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }
}

@MainActor
private final class NSHostingFixtureViewController: NSViewController {
    private let fixtureTitle: String

    init(title: String) {
        fixtureTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let label = NSTextField(labelWithString: fixtureTitle)
        label.font = .systemFont(ofSize: 22, weight: .semibold)

        let field = NSTextField(string: "")
        field.placeholderString = "Editable text"

        let button = NSButton(title: "Open Sheet", target: self, action: #selector(openSheet))

        let stack = NSStackView(views: [label, field, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        view = stack
    }

    @objc private func openSheet() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Fixture Sheet"
        alert.informativeText = "Sheets should remain fully native after handoff."
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window)
    }
}

@main
@MainActor
enum HaloPinFixture {
    private static let delegate = FixtureDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
