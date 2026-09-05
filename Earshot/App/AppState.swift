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

    // Navigation: the home screen pushes note detail onto this path.
    @Published var notePath: [UUID] = []
    @Published var showOnboarding = false
    // The persistent sidebar's current target.
    @Published var sidebar: SidebarSelection = .home

    @Published var hudVisible: Bool {
        didSet {
            UserDefaults.standard.set(hudVisible, forKey: "hudVisible")
            updateHUDVisibility()
        }
    }

    private var hudPanel: HUDPanel?

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

        HotkeyManager.shared.onNewNote = { [weak self] in
            guard let self else { return }
            if self.recorder.isActive {
                self.showCurrentNoteWindow()
            } else {
                self.startMeetingNote()
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

        // The floating lozenge is for when you are elsewhere; inside Earshot
        // the window has its own controls, so the HUD steps aside.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.refreshHUD() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.refreshHUD() }
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding = true
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
        if hudVisible && !NSApp.isActive {
            hudPanel.positionBottomCenter()
            hudPanel.orderFrontRegardless()
        } else {
            hudPanel.orderOut(nil)
        }
    }

    // MARK: - Actions

    func startMeetingNote(title: String? = nil) {
        guard !recorder.isActive else { return }
        Task {
            if let id = await recorder.start() {
                if let title, !title.isEmpty, var meta = store.meta(id: id) {
                    meta.title = title
                    meta.titleLocked = true
                    store.save(meta: meta)
                }
                notePath = [id]
                showMainWindow()
            } else {
                showMainWindow()
            }
        }
    }

    func stopMeetingNote() {
        Task { await recorder.stop() }
    }

    func resumeMeetingNote(id: UUID) {
        guard !recorder.isActive else { return }
        Task {
            _ = await recorder.resumeNote(id: id)
            notePath = [id]
            showMainWindow()
        }
    }

    func showMainWindow() {
        WindowManager.shared.showMain(app: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCurrentNoteWindow() {
        if let id = recorder.currentNoteID {
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
