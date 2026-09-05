import AppKit
import SwiftUI

// One main window, managed programmatically so the HUD and hotkeys can summon it.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?

    var isMainVisible: Bool { mainWindow?.isVisible ?? false }

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
            .environmentObject(app.calendar)
            .environmentObject(app.askStore)
            .environmentObject(app.chat)
            .environmentObject(app.spaces)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Oats"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 880, height: 560)
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
