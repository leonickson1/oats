import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store: NoteStore
    let agent: AgentBridge
    let recorder: MeetingRecorder
    let dictation: DictationController

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
        self.dictation = DictationController()
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
        HotkeyManager.shared.onDictationToggle = { [weak self] in
            self?.dictation.toggle()
        }
        HotkeyManager.shared.register()

        // Warm up the on-device speech model in the background.
        Task.detached(priority: .utility) {
            let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
            try? await TranscriberPipeline.ensureAssets(locale: locale)
        }

        showMainWindow()
    }

    private func updateHUDVisibility() {
        guard let hudPanel else { return }
        if hudVisible {
            hudPanel.positionBottomCenter()
            hudPanel.orderFrontRegardless()
        } else {
            hudPanel.orderOut(nil)
        }
    }

    // MARK: - Actions

    func startMeetingNote() {
        guard !recorder.isActive else { return }
        Task {
            if let id = await recorder.start() {
                WindowManager.shared.showNote(id: id, app: self)
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
            WindowManager.shared.showNote(id: id, app: self)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showMainWindow()
        }
    }

    func openNote(id: UUID) {
        WindowManager.shared.showNote(id: id, app: self)
        NSApp.activate(ignoringOtherApps: true)
    }
}
