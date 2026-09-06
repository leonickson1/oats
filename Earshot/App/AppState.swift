import SwiftUI
import Combine
import AppKit

// What the persistent left sidebar is pointing at. `.home` shows the notes list;
// the chat cases show a saved conversation in the main pane (Granola-style).
enum SidebarSelection: Hashable {
    case home
    case actions          // the cross-meeting action-items hub
    case graph            // the knowledge graph across meetings
    case chat(UUID)       // an Ask-popup conversation
    case noteChat(UUID)   // the in-meeting chat that lives inside a note
    case space(UUID)      // a workspace of meetings with its own chat
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store: NoteStore
    let agent: AgentBridge
    let recorder: MeetingRecorder
    let capture: CaptureManager
    let calendar: CalendarManager
    let askStore: AskStore
    let ask: AskController       // the summon popup (Opt+Space)
    let chat: ChatEngine        // the in-window ChatGPT-style conversation
    let spaces: SpaceStore      // workspaces of meetings
    let meetings = MeetingDetector()   // notices calls starting elsewhere
    let backdrop = HUDBackdrop()       // screen brightness behind the HUD

    // Navigation: the home screen pushes note detail onto this path.
    @Published var notePath: [UUID] = []
    @Published var showOnboarding = false
    // The persistent sidebar's current target.
    @Published var sidebar: SidebarSelection = .home
    // Companion shape: a narrow column docked to the side of the screen with
    // the sidebar hidden, for keeping notes next to a call. WindowManager owns
    // the frames; this flag is what the views read.
    @Published var companionMode = false

    @Published var hudVisible: Bool {
        didSet {
            UserDefaults.standard.set(hudVisible, forKey: "hudVisible")
            updateHUDVisibility()
        }
    }

    private var hudPanel: HUDPanel?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let store = NoteStore()
        let agent = AgentBridge()
        self.store = store
        self.agent = agent
        self.recorder = MeetingRecorder(store: store, agent: agent)
        self.capture = CaptureManager(store: store)
        self.calendar = CalendarManager()
        let askStore = AskStore()
        self.askStore = askStore
        let spaces = SpaceStore()
        self.spaces = spaces
        self.ask = AskController(agent: agent, store: store, history: askStore)
        self.chat = ChatEngine(agent: agent, store: store, history: askStore, spaces: spaces)
        self.hudVisible = UserDefaults.standard.object(forKey: "hudVisible") as? Bool ?? true
    }

    func bootstrap() {
        let panel = HUDPanel(content: HUDView(app: self))
        hudPanel = panel
        panel.positionBottomCenter()
        updateHUDVisibility()
        backdrop.start(panel: panel)
        meetings.start()
        // A detected call must be able to raise the HUD even when it was
        // stepped aside (Oats frontmost); a dismissal lowers it again.
        meetings.$current
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshHUD() }
            }
            .store(in: &cancellables)

        HotkeyManager.shared.onNewNote = { [weak self] in
            guard let self else { return }
            if self.recorder.isActive {
                self.showCurrentNoteWindow()
            } else {
                // The hotkey fires while you are elsewhere (in the call), so it
                // opens the companion column rather than the full window.
                self.startMeetingNote(companion: true)
            }
        }
        HotkeyManager.shared.onAsk = { [weak self] in
            self?.ask.toggle()
        }
        HotkeyManager.shared.register()

        // Warm up the on-device speech model in the background.
        Task.detached(priority: .utility) {
            let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
            try? await TranscriberPipeline.ensureAssets(locale: locale)
        }

        // Activation changes reposition the lozenge onto the screen you are
        // working on and re-sample the backdrop behind it.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.refreshHUD() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.refreshHUD() }
        }
        // Displays plugged, unplugged, or rearranged: put the lozenge back on a
        // screen that still exists.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.refreshHUD() }
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding = true
        }
        // QA hook: EARSHOT_QA_COMPANION=1 runs the exact HUD start path (real
        // recording, companion window) so the docked layout can be screenshotted.
        // "1" starts a companion recording and logs the frame; "2" additionally
        // toggles back to the full window to prove the restore path.
        if let qa = ProcessInfo.processInfo.environment["EARSHOT_QA_COMPANION"], qa == "1" || qa == "2" {
            Task { @MainActor in
                func frames() -> String {
                    NSApp.windows
                        .filter { $0.styleMask.contains(.titled) }
                        .map { "frame=\($0.frame) screenVisible=\(String(describing: $0.screen?.visibleFrame))" }
                        .joined(separator: "\n")
                }
                try? await Task.sleep(for: .seconds(1))
                self.startMeetingNote(companion: true)
                try? await Task.sleep(for: .seconds(4))
                var log = "companion: " + frames()
                if qa == "2" {
                    WindowManager.shared.toggleCompanion(app: self)
                    try? await Task.sleep(for: .seconds(2))
                    log += "\nexpanded: " + frames()
                }
                try? log.write(toFile: "/tmp/earshot-companion.txt", atomically: true, encoding: .utf8)
            }
        }
        // QA hook: EARSHOT_QA_SCROLL=1 docks the window as the companion on
        // Home, dumps every NSScrollView (document vs clip height) to
        // /tmp/earshot-scroll.txt, then scrolls the main one programmatically
        // so a screenshot can prove whether scrolling works at that size.
        if ProcessInfo.processInfo.environment["EARSHOT_QA_SCROLL"] == "1" {
            // Log every scroll-wheel event the app receives, so an externally
            // posted scroll can be traced: arrived-but-ignored vs never-arrived.
            _ = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let line = "scroll dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) loc=\(event.locationInWindow) win=\(event.window == nil ? "nil" : "yes")\n"
                if let data = line.data(using: .utf8) {
                    if let handle = FileHandle(forWritingAtPath: "/tmp/earshot-scrollevents.txt") {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    } else {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/earshot-scrollevents.txt"))
                    }
                }
                return event
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.sidebar = .home
                WindowManager.shared.showMain(app: self, companion: true)
                try? await Task.sleep(for: .seconds(3))
                var log = ""
                var scrollViews: [NSScrollView] = []
                func walk(_ view: NSView, depth: Int) {
                    let name = String(describing: type(of: view))
                    if let sv = view as? NSScrollView {
                        scrollViews.append(sv)
                        log += String(repeating: "  ", count: depth)
                            + "\(name) frame=\(view.frame) doc=\(sv.documentView?.frame.size ?? .zero) clip=\(sv.contentView.bounds) elasticity=\(sv.verticalScrollElasticity.rawValue)\n"
                    } else if depth < 6 {
                        log += String(repeating: "  ", count: depth)
                            + "\(name) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue)\n"
                    }
                    for sub in view.subviews { walk(sub, depth: depth + 1) }
                }
                if let content = WindowManager.shared.debugContentView { walk(content, depth: 0) }
                // Where would events land? Probe mid-window and log the full
                // superview chain of the hit view, so we can see whether it
                // lives inside the scroll view or floats above it.
                if let content = WindowManager.shared.debugContentView,
                   let hit = content.hitTest(NSPoint(x: 206, y: 450)) {
                    var chain: [String] = []
                    var cursor: NSView? = hit
                    while let v = cursor {
                        chain.append(String(describing: type(of: v)))
                        cursor = v.superview
                    }
                    log += "hit chain: " + chain.joined(separator: " < ") + "\n"
                    // Does the hit view forward scrollWheel up the responder
                    // chain? Feed it a real event directly.
                    if let main = scrollViews.max(by: { $0.frame.height < $1.frame.height }),
                       let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -240, wheel2: 0, wheel3: 0),
                       let event = NSEvent(cgEvent: cg) {
                        log += "direct before: \(main.contentView.bounds.origin)\n"
                        hit.scrollWheel(with: event)
                        try? await Task.sleep(for: .milliseconds(400))
                        log += "direct after: \(main.contentView.bounds.origin)\n"
                    }
                }
                // Send a real scroll-wheel event through the window's normal
                // routing (no permissions needed) and see if the content moves.
                if let window = WindowManager.shared.debugContentView?.window,
                   let main = scrollViews.max(by: { $0.frame.height < $1.frame.height }) {
                    log += "before event: \(main.contentView.bounds.origin)\n"
                    let winMid = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -240, wheel2: 0, wheel3: 0) {
                        let screenPoint = NSPoint(x: window.frame.midX, y: window.frame.midY)
                        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                        cg.location = CGPoint(x: screenPoint.x, y: mainScreenHeight - screenPoint.y)
                        if let event = NSEvent(cgEvent: cg) {
                            window.sendEvent(event)
                        }
                        log += "sent scroll at winMid=\(winMid)\n"
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    log += "after event: \(main.contentView.bounds.origin)\n"
                }
                try? log.write(toFile: "/tmp/earshot-scroll.txt", atomically: true, encoding: .utf8)
            }
        }
        // QA hook: EARSHOT_QA_GRAPH=1 opens the knowledge graph on launch so
        // the canvas layout can be screenshotted.
        if ProcessInfo.processInfo.environment["EARSHOT_QA_GRAPH"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.sidebar = .graph
            }
        }
        showMainWindow()
        UpdateChecker.shared.checkOnLaunchIfDue()
    }

    func refreshHUD() {
        updateHUDVisibility()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "didOnboard")
        showOnboarding = false
    }

    private func updateHUDVisibility() {
        guard let hudPanel else { return }
        // The lozenge is always there while it is enabled. It used to step
        // aside when Oats was frontmost, but that made it vanish under the
        // cursor the moment you pressed Stop with the window open, and then
        // reappear when you clicked elsewhere, which read as a bug. A steady
        // pill people can always find beats a clever one.
        if hudVisible {
            hudPanel.positionBottomCenter()
            hudPanel.orderFrontRegardless()
            // Adapt to what is behind it the moment it appears, not on the
            // next timer tick.
            backdrop.sampleSoon()
        } else {
            hudPanel.orderOut(nil)
        }
    }

    // MARK: - Actions

    // companion: true opens the window as the docked side column (HUD and
    // hotkey starts); false leaves the window in whatever shape it already has.
    func startMeetingNote(title: String? = nil, companion: Bool = false) {
        guard !recorder.isActive else { return }
        Task {
            if let id = await recorder.start() {
                if let title, !title.isEmpty, var meta = store.meta(id: id) {
                    meta.title = title
                    meta.titleLocked = true
                    store.save(meta: meta)
                }
                // Always land on the live note screen, whatever the sidebar was
                // showing before; without this, starting from the HUD left the
                // window sitting on the last-selected space or chat.
                sidebar = .home
                notePath = [id]
                showMainWindow(companion: companion ? true : nil)
            } else {
                showMainWindow(companion: companion ? true : nil)
            }
            refreshHUD()
        }
    }

    func stopMeetingNote() {
        Task {
            await recorder.stop()
            refreshHUD()
        }
    }

    func resumeMeetingNote(id: UUID) {
        guard !recorder.isActive else { return }
        Task {
            _ = await recorder.resumeNote(id: id)
            sidebar = .home
            notePath = [id]
            showMainWindow()
            refreshHUD()
        }
    }

    func showMainWindow(companion: Bool? = nil) {
        WindowManager.shared.showMain(app: self, companion: companion)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCurrentNoteWindow() {
        if let id = recorder.currentNoteID {
            sidebar = .home
            notePath = [id]
        }
        showMainWindow()
    }

    func openNote(id: UUID) {
        sidebar = .home
        notePath = [id]
        showMainWindow()
    }

    func toggleAsk() { ask.toggle() }

    // Start a fresh chat in the main window and drop the cursor in it. This is
    // what "+ New chat" does; the summon popup is just an optional shortcut.
    func newChatInWindow(attachTo noteID: UUID? = nil) {
        let id = chat.newChat(attachTo: noteID)
        sidebar = .chat(id)
        showMainWindow()
        chat.focusTick += 1
    }

    // Start a fresh chat that belongs to a space (nested under it in the sidebar).
    func newChatInSpace(spaceID: UUID) {
        let id = chat.newChat(inSpace: spaceID)
        sidebar = .chat(id)
        showMainWindow()
        chat.focusTick += 1
    }

    // Open a saved conversation as the active chat in the main window (used by
    // the sidebar and by the popup's "expand").
    func openChatInWindow(sessionID: UUID?) {
        if let id = sessionID {
            chat.loadSession(id: id)
            sidebar = .chat(id)
        }
        showMainWindow()
    }

    func showChat(_ selection: SidebarSelection) {
        sidebar = selection
        showMainWindow()
    }

    // Delete a saved chat; if it was the one on screen, fall back to Home.
    func deleteChat(id: UUID) {
        askStore.delete(id: id)
        if sidebar == .chat(id) { sidebar = .home }
    }

    func openSpace(id: UUID) {
        sidebar = .space(id)
        showMainWindow()
    }

    // Create a space and jump into it.
    func createSpace(name: String, symbol: String = SpaceGlyph.defaultSymbol) {
        let space = spaces.create(name: name, symbol: symbol)
        openSpace(id: space.id)
    }
}
