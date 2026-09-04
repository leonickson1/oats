import AppKit
import SwiftUI

// One main window, managed programmatically so the HUD and hotkeys can summon it.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?

    func showMain(app: AppState) {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let content = MainWindowView()
            .environmentObject(app)
            .environmentObject(app.store)
            .environmentObject(app.recorder)
            .environmentObject(app.agent)
            .environmentObject(app.capture)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Earshot"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            if window == self.mainWindow { self.mainWindow = nil }
        }
    }
}
