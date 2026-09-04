import AppKit
import SwiftUI

// Programmatic window management: one main window, one window per open note.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?
    private var noteWindows: [UUID: NSWindow] = [:]

    func showMain(app: AppState) {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let content = MainWindowView()
            .environmentObject(app)
            .environmentObject(app.store)
            .environmentObject(app.recorder)
            .environmentObject(app.dictation)
            .environmentObject(app.agent)
        let window = makeWindow(content: AnyView(content), size: NSSize(width: 1060, height: 700))
        window.title = "Earshot"
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    func showNote(id: UUID, app: AppState) {
        if let existing = noteWindows[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let content = NoteWindowView(noteID: id)
            .environmentObject(app)
            .environmentObject(app.store)
            .environmentObject(app.recorder)
            .environmentObject(app.agent)
        let window = makeWindow(content: AnyView(content), size: NSSize(width: 620, height: 760))
        window.title = "Note"
        if let main = mainWindow, main.isVisible {
            let frame = main.frame
            window.setFrameOrigin(NSPoint(x: frame.maxX - 640, y: frame.minY + 20))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        noteWindows[id] = window
    }

    private func makeWindow(content: AnyView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 420)
        window.backgroundColor = NSColor(Theme.windowBG)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            if window == self.mainWindow { self.mainWindow = nil }
            self.noteWindows = self.noteWindows.filter { $0.value != window }
        }
    }
}
