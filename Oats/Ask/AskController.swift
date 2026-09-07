import AppKit
import SwiftUI
import Combine

enum AskMode {
    case compact   // just the bar
    case answer    // bar + conversation
    case max       // large, centered
}

// Owns the summonable Ask panel and its conversation. Backed by the same local
// agents (Claude Code / Codex / Ollama) as the rest of the app; the model is
// chosen from what the user has connected.
@MainActor
final class AskController: ObservableObject {
    @Published var query = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var mode: AskMode = .compact
    @Published var errorText: String?
    @Published var focusTick = 0

    private unowned let agent: AgentBridge
    private unowned let store: NoteStore
    private unowned let history: AskStore
    private var panel: AskPanel?
    private var currentSessionID: UUID?

    private let width: CGFloat = 620
    private let compactHeight: CGFloat = 92
    private let answerHeight: CGFloat = 560
    private let maxSize = NSSize(width: 960, height: 760)

    init(agent: AgentBridge, store: NoteStore, history: AskStore) {
        self.agent = agent
        self.store = store
        self.history = history
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = AskPanel(contentRect: frame(for: .compact))
        p.onEscape = { [weak self] in self?.dismiss() }
        let hosting = NSHostingView(rootView: AskPopupView(controller: self, agent: agent))
        hosting.sizingOptions = []
        p.contentView = hosting
        panel = p
    }

    func toggle() {
        ensurePanel()
        guard let panel else { return }
        if panel.isVisible && panel.isKeyWindow {
            dismiss()
        } else if panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            focusTick += 1
        } else {
            show()
        }
    }

    func show() {
        ensurePanel()
        guard let panel else { return }
        panel.setFrame(frame(for: mode), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusTick += 1
    }

    func dismiss() {
        panel?.orderOut(nil)
        // Closing the popup must never take the main window with it. Only hide the
        // app (to return focus to the previous app, Spotlight-style) when there is
        // no Oats window open behind the popup.
        if !WindowManager.shared.isMainVisible {
            NSApp.hide(nil)
        }
    }

    private func setMode(_ newMode: AskMode) {
        mode = newMode
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame(for: newMode), display: true)
        }
    }

    func toggleMaximize() {
        setMode(mode == .max ? .answer : .max)
    }

    private func frame(for mode: AskMode) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        switch mode {
        case .compact:
            return NSRect(x: screen.midX - width / 2, y: screen.minY + 40, width: width, height: compactHeight)
        case .answer:
            let h = min(answerHeight, screen.height - 80)
            return NSRect(x: screen.midX - width / 2, y: screen.minY + 40, width: width, height: h)
        case .max:
            let w = min(maxSize.width, screen.width - 120)
            let h = min(maxSize.height, screen.height - 120)
            return NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
        }
    }

    // MARK: - Conversation

    func newChat() {
        messages = []
        query = ""
        errorText = nil
        currentSessionID = nil
        setMode(.compact)
        focusTick += 1
    }

    // Reopen a saved conversation in the popup.
    func open(session: AskSession) {
        messages = session.messages
        currentSessionID = session.id
        query = ""
        errorText = nil
        mode = .answer
        show()
    }

    func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        query = ""
        errorText = nil
        let userMessage = ChatMessage(role: "user", text: q)
        messages.append(userMessage)
        if mode == .compact { setMode(.answer) }
        persist()   // save the question immediately, even if the answer fails

        let priorTurns = Array(messages.dropLast())   // excludes the new question
        let placeholder = ChatMessage(role: "assistant", text: "")
        messages.append(placeholder)
        isStreaming = true

        Task {
            let notes = store.notes.prefix(8).map { (meta: $0, summary: store.loadSummary(noteID: $0.id)) }
            let prompt = AgentPrompts.ask(question: q, history: priorTurns, notes: notes)
            var streamed = ""
            do {
                let answer = try await agent.runStreaming(prompt: prompt) { [weak self] delta in
                    streamed += delta
                    self?.updatePlaceholder(id: placeholder.id, text: streamed)
                }
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.removeAll { $0.id == placeholder.id }
                    errorText = "\(agent.activeAgentName) returned nothing. Check the model is connected in Settings."
                } else {
                    updatePlaceholder(id: placeholder.id, text: answer)
                }
            } catch {
                messages.removeAll { $0.id == placeholder.id && $0.text.isEmpty }
                errorText = error.localizedDescription
            }
            isStreaming = false
            persist()
        }
    }

    // Save the current conversation and hand it to the main window's chat so the
    // user can keep going there (ChatGPT-style). The popup then resets to empty,
    // since it is just a quick entry point. Orders the panel out directly instead
    // of dismiss() so we don't hide the app right before re-activating it.
    func openInMainWindow() {
        persist()
        let id = currentSessionID
        panel?.orderOut(nil)
        AppState.shared.openChatInWindow(sessionID: id)
        resetToEmpty()
    }

    private func resetToEmpty() {
        messages = []
        query = ""
        errorText = nil
        currentSessionID = nil
        mode = .compact
    }

    private func persist() {
        let real = messages.filter { !($0.role == "assistant" && $0.text.isEmpty) }
        guard real.contains(where: { $0.role == "user" }) else { return }
        let id = currentSessionID ?? UUID()
        currentSessionID = id
        let existing = history.session(id: id)
        let title = existing?.title ?? String((real.first { $0.role == "user" }?.text ?? "Conversation").prefix(48))
        let created = existing?.createdAt ?? Date()
        // Tie the conversation to the meeting in focus when it started, and keep
        // that link for the life of the conversation.
        let noteID = existing?.noteID ?? contextNoteID
        let noteTitle = existing?.noteTitle ?? noteID.flatMap { store.meta(id: $0)?.title }
        history.save(AskSession(id: id, title: title, createdAt: created, updatedAt: Date(),
                                messages: real, noteID: noteID, noteTitle: noteTitle))
    }

    // The meeting a new Ask conversation should attach to: the live recording if
    // any, otherwise the note currently open in the main window.
    private var contextNoteID: UUID? {
        if let live = AppState.shared.recorder.currentNoteID { return live }
        return AppState.shared.notePath.last
    }

    func ask(_ prompt: String) {
        query = prompt
        submit()
    }

    private func updatePlaceholder(id: UUID, text: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = ChatMessage(role: "assistant", text: text, id: id)
        }
    }
}
