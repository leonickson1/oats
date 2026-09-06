import AppKit
import SwiftUI

// Floating, non-activating panel at the bottom center of the screen.
// Non-activating is essential: clicking dictation controls must not steal
// focus from the app receiving the inserted text.
final class HUDPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        // Starts dark; HUDBackdrop flips this live to match what is behind the
        // panel, so vibrancy renders dark ink over light content and vice versa.
        appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: content)
        // The panel hugs its SwiftUI content, so transparent dead zones never
        // swallow clicks meant for the app behind it.
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting

        NotificationCenter.default.addObserver(
            forObject: self, name: NSWindow.didResizeNotification
        ) { [weak self] in
            self?.positionBottomCenter()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 10
        ))
    }
}

private extension NotificationCenter {
    func addObserver(forObject object: Any, name: NSNotification.Name, handler: @escaping () -> Void) {
        addObserver(forName: name, object: object, queue: .main) { _ in handler() }
    }
}
