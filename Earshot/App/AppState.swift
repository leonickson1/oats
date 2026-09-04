import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store: NoteStore
    let agent: AgentBridge
    let recorder: MeetingRecorder
    let capture: CaptureManager
    let calendar: CalendarManager

    // Navigation: the home screen pushes note detail onto this path.
    @Published var notePath: [UUID] = []
    @Published var showOnboarding = false

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
        notePath = [id]
        showMainWindow()
    }
}
