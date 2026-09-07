import SwiftUI
import Combine

// The active conversation shown in the main window's chat view. It is a first
// class chat (ChatGPT-style): you type here, answers stream in, and everything
// persists to the same AskStore the summon popup writes to. A meeting can be
// attached as context, but the chat is its own thing, not a note.
@MainActor
final class ChatEngine: ObservableObject {
    @Published var query = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published var errorText: String?
    @Published private(set) var activeSessionID: UUID?
    // Meeting this new chat is attached to (nil = a general chat).
    @Published var attachedNoteID: UUID?
    // Space this chat belongs to, if opened from a space.
    @Published var attachedSpaceID: UUID?
    // The meetings the user has chosen to ask about. Empty = ask across recent
    // meetings automatically.
    @Published var selectedMeetingIDs: Set<UUID> = []
    @Published var focusTick = 0

    private unowned let agent: AgentBridge
    private unowned let store: NoteStore
    private unowned let history: AskStore
    private unowned let spaces: SpaceStore

    init(agent: AgentBridge, store: NoteStore, history: AskStore, spaces: SpaceStore) {
        self.agent = agent
        self.store = store
        self.history = history
        self.spaces = spaces
    }

    // The meetings this chat actually asks about, derived from what it's tied to:
    // a space's current membership, a single meeting, an explicit pick, or the
    // recent meetings as a fallback for a general chat.
    var contextNotes: [NoteMeta] {
        if let sid = attachedSpaceID, let space = spaces.space(id: sid) {
            return space.noteIDs.compactMap { store.meta(id: $0) }
        }
        if !selectedMeetingIDs.isEmpty {
            return store.notes.filter { selectedMeetingIDs.contains($0.id) }
        }
        if let nid = attachedNoteID, let meta = store.meta(id: nid) {
            return [meta]
        }
        return Array(store.notes.prefix(8))
    }

    // Start a brand-new, empty conversation and return its id so the caller can
    // select it in the sidebar right away.
    @discardableResult
    func newChat(attachTo noteID: UUID? = nil, inSpace spaceID: UUID? = nil) -> UUID {
        let id = UUID()
        messages = []
        query = ""
        errorText = nil
        activeSessionID = id
        attachedNoteID = noteID
        attachedSpaceID = spaceID
        selectedMeetingIDs = []
        focusTick += 1
        return id
    }

    // Make an existing saved conversation the active one (from the sidebar).
    func loadSession(id: UUID) {
        guard activeSessionID != id else { return }
        if let session = history.session(id: id) {
            messages = session.messages
            activeSessionID = id
            attachedNoteID = session.noteID
            attachedSpaceID = session.spaceID
        } else {
            messages = []
            activeSessionID = id
            attachedNoteID = nil
            attachedSpaceID = nil
        }
        selectedMeetingIDs = []
        query = ""
        errorText = nil
    }

    // Enter a space's chat: continue its saved thread (or start one). Scope is
    // derived live from the space's membership (see contextNotes), so an empty
    // space asks about nothing, never a stray "recent meetings" fallback.
    func enterSpace(id spaceID: UUID) {
        guard attachedSpaceID != spaceID || activeSessionID == nil else { return }
        if let existing = history.sessions.first(where: { $0.spaceID == spaceID }) {
            messages = existing.messages
            activeSessionID = existing.id
        } else {
            messages = []
            activeSessionID = UUID()
        }
        attachedSpaceID = spaceID
        attachedNoteID = nil
        selectedMeetingIDs = []
        query = ""
        errorText = nil
        focusTick += 1
    }

    // Take over a conversation started in the popup ("expand").
    func adopt(_ session: AskSession) {
        messages = session.messages
        activeSessionID = session.id
        attachedNoteID = session.noteID
        attachedSpaceID = session.spaceID
        selectedMeetingIDs = []
        query = ""
        errorText = nil
        focusTick += 1
    }

    func ask(_ prompt: String) {
        query = prompt
        submit()
    }

    // Turn a one-shot question/answer (from the Home bar or popup) into a real
    // saved conversation the user can continue.
    @discardableResult
    func startFrom(question: String, answer: String, attachTo noteID: UUID? = nil, spaceID: UUID? = nil) -> UUID {
        let id = UUID()
        messages = [ChatMessage(role: "user", text: question), ChatMessage(role: "assistant", text: answer)]
        activeSessionID = id
        attachedNoteID = noteID
        attachedSpaceID = spaceID
        selectedMeetingIDs = []
        query = ""
        errorText = nil
        persist()
        focusTick += 1
        return id
    }

    func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        query = ""
        errorText = nil
        if activeSessionID == nil { activeSessionID = UUID() }
        messages.append(ChatMessage(role: "user", text: q))
        persist()   // save the question immediately, even if the answer fails

        let priorTurns = Array(messages.dropLast())
        let placeholder = ChatMessage(role: "assistant", text: "")
        messages.append(placeholder)
        isStreaming = true

        let chosen = contextNotes

        Task {
            let notes = chosen.map { (meta: $0, summary: store.loadSummary(noteID: $0.id)) }
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

    private func persist() {
        let real = messages.filter { !($0.role == "assistant" && $0.text.isEmpty) }
        guard real.contains(where: { $0.role == "user" }) else { return }
        let id = activeSessionID ?? UUID()
        activeSessionID = id
        let existing = history.session(id: id)
        let title = existing?.title ?? String((real.first { $0.role == "user" }?.text ?? "Conversation").prefix(48))
        let created = existing?.createdAt ?? Date()
        let noteID = existing?.noteID ?? attachedNoteID
        let noteTitle = existing?.noteTitle ?? noteID.flatMap { store.meta(id: $0)?.title }
        let spaceID = existing?.spaceID ?? attachedSpaceID
        history.save(AskSession(id: id, title: title, createdAt: created, updatedAt: Date(),
                                messages: real, noteID: noteID, noteTitle: noteTitle, spaceID: spaceID))
    }

    private func updatePlaceholder(id: UUID, text: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = ChatMessage(role: "assistant", text: text, id: id)
        }
    }
}
