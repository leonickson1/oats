import SwiftUI
import AppKit

// The persistent left rail, Granola-style: your meetings and every chat live
// here, always visible, and clicking one opens it in the main pane. No hidden
// history modal.
struct ChatSidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var askStore: AskStore
    @EnvironmentObject var spaces: SpaceStore
    @EnvironmentObject var recorder: MeetingRecorder
    @State private var showNewSpace = false
    @State private var newSpaceName = ""
    @State private var expanded: Set<UUID> = []
    @State private var renameTarget: RenameTarget?
    @State private var spaceRenameTarget: Space?
    @State private var spaceRenameText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                EarshotLogoView(color: .primary, size: 18)
                Text("Oats")
                    .font(.system(size: 17, weight: .medium, design: .serif))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let label = recorder.enrichmentLabel {
                EnrichmentIndicator(label: label)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            List(selection: Binding(
                get: { app.sidebar },
                set: { app.sidebar = $0 ?? .home }
            )) {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.home)
                Label("Action items", systemImage: "checklist")
                    .tag(SidebarSelection.actions)
                Label("Knowledge graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(SidebarSelection.graph)

                Section("Spaces") {
                    ForEach(spaces.spaces) { space in
                        spaceRow(space)
                            .tag(SidebarSelection.space(space.id))
                            .contextMenu {
                                Button("Open") { app.openSpace(id: space.id) }
                                Button("Rename and change icon") {
                                    spaceRenameText = space.name
                                    spaceRenameTarget = space
                                }
                                Button("New chat in space") { app.newChatInSpace(spaceID: space.id) }
                                Divider()
                                Button("Delete space", role: .destructive) { spaces.delete(id: space.id) }
                            }

                        if expanded.contains(space.id) {
                            let sessions = spaceSessions(space.id)
                            ForEach(sessions) { session in
                                spaceChatChild(session)
                                    .tag(SidebarSelection.chat(session.id))
                                    .contextMenu {
                                        Button("Rename") { renameTarget = RenameTarget(id: session.id, title: session.title) }
                                        Button("Delete", role: .destructive) { app.deleteChat(id: session.id) }
                                    }
                            }
                            Button { app.newChatInSpace(spaceID: space.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .medium))
                                    Text(sessions.isEmpty ? "Start a chat here" : "New chat")
                                        .font(.system(size: 12))
                                }
                                .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 22)
                        }
                    }
                    Button {
                        newSpaceName = ""
                        showNewSpace = true
                    } label: {
                        Label("New space", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    if chatItems.isEmpty {
                        Text("Ask something with \(HotkeyManager.askDisplay), or chat inside a meeting. It shows up here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(chatItems) { item in
                            chatRow(item)
                                .tag(item.selection)
                                .contextMenu {
                                    if case .chat(let id) = item.selection {
                                        Button("Rename") { renameTarget = RenameTarget(id: id, title: item.title) }
                                        Button("Delete", role: .destructive) { app.deleteChat(id: id) }
                                    }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Chats")
                        Spacer()
                        Button {
                            app.newChatInWindow()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New chat")
                        .padding(.trailing, 10)
                    }
                }
            }
            .listStyle(.sidebar)

            sidebarFooter
        }
        .animation(Motion.quick, value: recorder.enrichmentLabel)
        .sheet(isPresented: $showNewSpace) {
            NewSpaceSheet(name: $newSpaceName) { name, symbol in
                app.createSpace(name: name, symbol: symbol)
            }
        }
        .sheet(item: $renameTarget) { target in
            RenameSheet(title: "Rename chat", text: target.title) { newName in
                askStore.rename(id: target.id, to: newName)
            }
        }
        .sheet(item: $spaceRenameTarget) { space in
            NewSpaceSheet(name: $spaceRenameText,
                          initialSymbol: space.symbol,
                          title: "Rename space",
                          confirmLabel: "Save") { name, symbol in
                spaces.rename(id: space.id, to: name, symbol: symbol)
            }
        }
    }

    // Pinned to the bottom of the rail: start a new note, and open Settings.
    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            if recorder.isActive {
                Button { app.showCurrentNoteWindow() } label: {
                    HStack(spacing: 7) {
                        WaveformBars(levels: recorder.levels, barColor: Theme.record, barCount: 5, maxHeight: 12)
                        Text(recorder.elapsed.clockString)
                            .font(.system(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.record)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(Capsule())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .help("Recording, open the note")
            } else {
                Button { app.startMeetingNote() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 52, height: 34)
                        .contentShape(Capsule())
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .help("New note  Opt+M")
            }

            Spacer(minLength: 0)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // A space in the rail: a chevron that expands its chats, its icon, its name.
    private func spaceRow(_ space: Space) -> some View {
        HStack(spacing: 7) {
            Button {
                toggleExpanded(space.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded.contains(space.id) ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded.contains(space.id) ? "Collapse" : "Show chats")

            SpaceIcon(symbol: space.symbol, size: 14)
            Text(space.name)
                .lineLimit(1)
        }
    }

    private func spaceChatChild(_ session: AskSession) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(session.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.leading, 22)
        .padding(.vertical, 1)
    }

    private func spaceSessions(_ id: UUID) -> [AskSession] {
        askStore.sessions
            .filter { $0.spaceID == id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func toggleExpanded(_ id: UUID) {
        withAnimation(Motion.standard) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func chatRow(_ item: ChatItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Text(item.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // Every conversation, newest first: Ask-popup sessions plus the in-meeting
    // chat that lives inside each note.
    private var chatItems: [ChatItem] {
        var items: [ChatItem] = []

        for session in askStore.sessions {
            // Space chats live inside their space, not the general chat list.
            if session.spaceID != nil { continue }
            let meeting = session.noteID.flatMap { store.meta(id: $0)?.title } ?? session.noteTitle
            items.append(ChatItem(
                selection: .chat(session.id),
                title: session.title,
                meeting: meeting,
                date: session.updatedAt,
                icon: "bubble.left"
            ))
        }

        for note in store.notes {
            let chat = store.loadChat(noteID: note.id)
            guard !chat.isEmpty else { continue }
            items.append(ChatItem(
                selection: .noteChat(note.id),
                title: "Chat in \(note.title)",
                meeting: note.title,
                date: note.createdAt,
                icon: "text.bubble"
            ))
        }

        return items.sorted { $0.date > $1.date }
    }
}

struct RenameTarget: Identifiable { let id: UUID; var title: String }

// A minimal sheet to rename a chat (or anything with a single text field).
struct RenameSheet: View {
    var title: String
    @State var text: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 16, weight: .semibold))
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

// A quiet, glassy status shown while the local model enriches notes in the
// background, so people know the graph and action items are updating.
struct EnrichmentIndicator: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.record)
                .symbolEffect(.pulse, options: .repeating)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct ChatItem: Identifiable {
    let selection: SidebarSelection
    let title: String
    let meeting: String?
    let date: Date
    let icon: String

    var id: SidebarSelection { selection }
    var subtitle: String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        if let meeting { return "\(meeting) · \(when)" }
        return "General · \(when)"
    }
}

// The main pane when a chat is selected: a live, ChatGPT-style conversation you
// can keep typing in. Ask sessions are the active chats (driven by ChatEngine);
// a note's in-meeting chat shows read-only with a jump back to the meeting.
struct ChatConversationView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var askStore: AskStore
    @EnvironmentObject var chat: ChatEngine
    @EnvironmentObject var agent: AgentBridge

    let selection: SidebarSelection

    var body: some View {
        Group {
            switch selection {
            case .noteChat(let noteID):
                noteChatView(noteID)
            default:
                activeChatView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
    }

    // MARK: - Active chat (ChatGPT-style)

    private var activeChatView: some View {
        ActiveChatView(selection: selection)
            .environmentObject(app)
            .environmentObject(store)
            .environmentObject(chat)
            .environmentObject(agent)
    }

    // MARK: - Read-only note chat

    private func noteChatView(_ noteID: UUID) -> some View {
        let messages = store.loadChat(noteID: noteID)
        return ConversationScroll(messages: messages, isStreaming: false, agentName: "")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ToolbarTitleLabel(text: "Chat in \(store.meta(id: noteID)?.title ?? "meeting")")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { app.openNote(id: noteID) } label: {
                        Label("Open meeting", systemImage: "arrow.up.forward.app")
                    }
                }
            }
    }
}

// The reusable message list, shared by the active chat and the read-only view.
struct ConversationScroll: View {
    let messages: [ChatMessage]
    let isStreaming: Bool
    let agentName: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        if message.role == "user" {
                            HStack {
                                Spacer(minLength: 48)
                                Text(message.text)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 9)
                                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        } else if message.text.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(agentName.isEmpty ? "Thinking" : "Thinking with \(agentName)")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                MarkdownView(text: message.text)
                                    .textSelection(.enabled)
                                if message.id != messages.last?.id || !isStreaming {
                                    CopyButton(text: message.text)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 0).id(message.id)
                    }
                    Color.clear.frame(height: 2).id("chatBottom")
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { withAnimation { proxy.scrollTo("chatBottom") } }
            .onChange(of: messages.last?.text) { withAnimation { proxy.scrollTo("chatBottom") } }
        }
    }
}

// The active conversation for the sidebar: loads the selected session into the
// engine, adds the toolbar, and shows the reusable chat body.
struct ActiveChatView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var chat: ChatEngine

    let selection: SidebarSelection

    private var sessionID: UUID? {
        if case .chat(let id) = selection { return id }
        return nil
    }

    var body: some View {
        ChatBody()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ToolbarTitleLabel(text: chat.messages.isEmpty ? "New chat" : title)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { app.newChatInWindow() } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .help("Start a new chat")
                }
            }
            .onAppear { load() }
            .onChange(of: selection) { load() }
    }

    private func load() {
        if case .chat(let id) = selection { chat.loadSession(id: id) }
    }

    private var title: String {
        if let id = sessionID, let s = app.askStore.session(id: id) { return s.title }
        return "Chat"
    }
}

// The reusable chat surface (no toolbar): meeting context bar + conversation +
// composer. Used by the standalone chat and inside a space.
struct ChatBody: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var chat: ChatEngine
    @EnvironmentObject var agent: AgentBridge
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !store.notes.isEmpty {
                MeetingContextBar(chat: chat)
                Divider().opacity(0.4)
            }
            if chat.messages.isEmpty {
                emptyState
            } else {
                ConversationScroll(messages: chat.messages, isStreaming: chat.isStreaming, agentName: agent.activeAgentName)
            }
            if let error = chat.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }
            composer
        }
        .onAppear { focused = true }
        .onChange(of: chat.focusTick) { focused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            EarshotLogoView(color: .secondary, size: 30)
            Text("Ask anything")
                .font(.system(size: 16, weight: .semibold, design: .serif))
            Text("Chat across all your meetings. Answers run on your local AI, \(agent.activeAgentName).")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasText: Bool { !chat.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Oats", text: $chat.query, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { chat.submit() }
                ModelPickerMenu(agent: agent)
                    .padding(.bottom, 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            Button { chat.submit() } label: {
                ZStack {
                    Circle()
                        .fill(hasText ? Theme.record : Color.secondary.opacity(0.25))
                        .frame(width: 34, height: 34)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(hasText ? .white : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasText || chat.isStreaming)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

// Compact model picker with a provider glyph, meant to live at the trailing edge
// inside an input field. Claude Code and Ollama expand to their model lists.
struct ModelPickerMenu: View {
    @ObservedObject var agent: AgentBridge
    var tint: Color = .secondary

    var body: some View {
        Menu {
            Button { agent.preference = .auto } label: { menuLabel("Auto", selected: agent.preference == .auto) }
            if agent.availability.claudePath != nil {
                Menu("Claude Code") {
                    Button { agent.preference = .claudeCode; agent.claudeModel = "" } label: {
                        menuLabel("Default", selected: agent.preference == .claudeCode && agent.claudeModel.isEmpty)
                    }
                    ForEach(agent.claudeModels, id: \.self) { model in
                        Button { agent.preference = .claudeCode; agent.claudeModel = model } label: {
                            menuLabel(model.capitalized, selected: agent.preference == .claudeCode && agent.claudeModel == model)
                        }
                    }
                }
            }
            if agent.availability.codexPath != nil {
                Button { agent.preference = .codex } label: { menuLabel("Codex", selected: agent.preference == .codex) }
            }
            if agent.appleAvailable {
                Button { agent.preference = .apple } label: { menuLabel("Apple Intelligence", selected: agent.preference == .apple) }
            }
            if !agent.ollamaModels.isEmpty {
                Menu("Ollama") {
                    ForEach(agent.ollamaModels, id: \.self) { model in
                        Button { agent.preference = .ollama; agent.ollamaModel = model } label: {
                            menuLabel(model, selected: agent.preference == .ollama && agent.ollamaModel == model)
                        }
                    }
                }
            }
            Divider()
            Button { agent.preference = .none } label: { menuLabel("Off", selected: agent.preference == .none) }
            Button { Task { await agent.detect() } } label: { Label("Refresh models", systemImage: "arrow.clockwise") }
        } label: {
            HStack(spacing: 4) {
                ProviderMark(provider: Provider.from(agent.preference), size: 13, color: tint)
                Text(currentLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .foregroundStyle(tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func menuLabel(_ title: String, selected: Bool) -> some View {
        Label { Text(title) } icon: { if selected { Image(systemName: "checkmark") } }
    }

    private var currentLabel: String {
        switch agent.preference {
        case .auto: return "Auto"
        case .claudeCode: return agent.claudeModel.isEmpty ? "Claude" : agent.claudeModel.capitalized
        case .codex: return "Codex"
        case .ollama: return agent.ollamaModel.isEmpty ? "Ollama" : agent.ollamaModel
        case .apple: return "Apple"
        case .none: return "Off"
        }
    }
}

// The meetings a chat can see, pinned above the conversation. Each chip opens
// its meeting; for a general chat, the filter picks exactly which meetings feed
// the AI. A space chat is scoped to the space, so it shows that, no filter.
struct MeetingContextBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @ObservedObject var chat: ChatEngine

    private var inSpace: Bool { chat.attachedSpaceID != nil }

    private var label: String {
        if inSpace { return "In this space" }
        if chat.selectedMeetingIDs.isEmpty { return "Recent meetings" }
        return "Asking about"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize()

            if inSpace && chat.contextNotes.isEmpty {
                Text("No meetings added yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.contextNotes) { note in
                            Button { app.openNote(id: note.id) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 9.5))
                                    Text(note.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.quaternary.opacity(0.45), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(note.title)")
                        }
                    }
                }
            }

            if !inSpace {
                Menu {
                    Button { chat.selectedMeetingIDs = [] } label: {
                        picker("All recent meetings", on: chat.selectedMeetingIDs.isEmpty)
                    }
                    if !store.notes.isEmpty { Divider() }
                    ForEach(store.notes.prefix(40)) { note in
                        Button {
                            if chat.selectedMeetingIDs.contains(note.id) {
                                chat.selectedMeetingIDs.remove(note.id)
                            } else {
                                chat.selectedMeetingIDs.insert(note.id)
                            }
                        } label: {
                            picker(note.title, on: chat.selectedMeetingIDs.contains(note.id))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 12))
                        Text("Choose")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func picker(_ title: String, on: Bool) -> some View {
        Label { Text(title) } icon: { if on { Image(systemName: "checkmark") } }
    }
}
