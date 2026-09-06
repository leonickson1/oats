import AppKit
import SwiftUI

// One main window, managed programmatically so the HUD and hotkeys can summon it.
// It has two shapes: the full app, and a "companion" column docked to the side
// of the screen for use during a call (sidebar hidden, note front and center).
// The toolbar button in MainWindowView toggles between them; starting a note
// from the HUD or the hotkey opens straight into the companion.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?
    private var savedFullFrame: NSRect?   // where the full window was before docking

    private static let fullMinSize = NSSize(width: 880, height: 560)
    private static let companionMinSize = NSSize(width: 400, height: 520)

    var isMainVisible: Bool { mainWindow?.isVisible ?? false }

    // For QA hooks only: lets the scroll diagnostic walk the AppKit hierarchy.
    var debugContentView: NSView? { mainWindow?.contentView }

    func showMain(app: AppState, companion: Bool? = nil) {
        if mainWindow == nil { buildWindow(app: app) }
        guard let window = mainWindow else { return }
        if let companion, companion != app.companionMode {
            apply(companion: companion, animate: window.isVisible)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func toggleCompanion(app: AppState) {
        apply(companion: !app.companionMode, animate: true)
    }

    private func apply(companion: Bool, animate: Bool) {
        guard let window = mainWindow else { return }
        let app = AppState.shared
        if companion {
            if !app.companionMode { savedFullFrame = window.frame }
            app.companionMode = true
            window.minSize = Self.companionMinSize
            let visible = Self.screenUnderMouse().visibleFrame
            // Never animated: an animated shrink negotiates with the still-
            // collapsing sidebar's layout, gets clamped to the old minimum
            // width, and leaves the window hanging off the screen edge.
            window.setFrame(Self.companionFrame(in: visible), display: true)
            settleCompanionFrame()
        } else {
            app.companionMode = false
            window.minSize = Self.fullMinSize
            window.setFrame(restoredFullFrame(), display: true, animate: animate)
        }
    }

    // The sidebar keeps animating for a beat after the frame lands, and that
    // layout pass can undo the size or the minimum. Re-assert both once it has
    // settled, so the docked column always ends exactly inside the screen.
    private func settleCompanionFrame() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard AppState.shared.companionMode, let window = mainWindow else { return }
            window.minSize = Self.companionMinSize
            let visible = (window.screen ?? Self.screenUnderMouse()).visibleFrame
            let target = Self.companionFrame(in: visible)
            if abs(window.frame.width - target.width) > 1 || !visible.contains(window.frame) {
                window.setFrame(target, display: true)
            }
        }
    }

    // The screen the user is working on right now: where the mouse is. This is
    // what makes multi-monitor behave; the companion docks where you clicked,
    // not on whichever display is "main".
    static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    // A tall narrow column hugging the trailing edge, like a call sidebar.
    // Pure geometry so the self-test can exercise it.
    nonisolated static func companionFrame(in visible: NSRect) -> NSRect {
        let margin: CGFloat = 12
        let width = min(480, max(400, visible.width * 0.28))
        let height = visible.height - margin * 2
        return NSRect(
            x: visible.maxX - width - margin,
            y: visible.minY + margin,
            width: width,
            height: height
        )
    }

    private func restoredFullFrame() -> NSRect {
        // Restore where the full window was, as long as that spot still exists
        // (the display it was on may have been unplugged since).
        if let saved = savedFullFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            return saved
        }
        let visible = Self.screenUnderMouse().visibleFrame
        let size = NSSize(width: min(1060, visible.width - 40), height: min(720, visible.height - 40))
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func buildWindow(app: AppState) {
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
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: content)
        // We manage minimum sizes ourselves (full vs companion). Left on, the
        // hosting view's own minimum (sidebar + detail) clamps the companion
        // frame the instant it is set, before the sidebar has collapsed.
        hosting.sizingOptions = []
        // Always bridge SwiftUI's .toolbar through the hosting view. The
        // companion (no split view) has no other way to get its Expand button,
        // and explicitly setting this to [] kills the FULL window's toolbar
        // too, so it stays on for both shapes.
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentView = hosting
        // A window reopened mid-call keeps the shape it had when it closed.
        if app.companionMode {
            window.minSize = Self.companionMinSize
            window.setFrame(Self.companionFrame(in: Self.screenUnderMouse().visibleFrame), display: false)
            settleCompanionFrame()
        } else {
            window.minSize = Self.fullMinSize
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    // SwiftUI keeps rewriting window.minSize to zero with hosting sizing
    // disabled, so the floor for user resizes is enforced here instead. This
    // is only consulted for user drags, never for our own setFrame calls.
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        MainActor.assumeIsolated {
            let floor = AppState.shared.companionMode ? Self.companionMinSize : Self.fullMinSize
            return NSSize(width: max(frameSize.width, floor.width),
                          height: max(frameSize.height, floor.height))
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            if window == self.mainWindow { self.mainWindow = nil }
        }
    }
}
