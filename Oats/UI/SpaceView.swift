import SwiftUI
import AppKit

// A space, laid out like Home: its name at the top, its meetings below, and a
// scoped ask bar pinned at the bottom. Chats you open from here belong to the
// space (they don't clutter the global chat list).
struct SpaceView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var spaces: SpaceStore
    @EnvironmentObject var agent: AgentBridge

    let spaceID: UUID

    @State private var askText = ""
    @State private var lastAsk = ""
    @State private var askAnswer: String?
    @State private var askError: String?
    @State private var isAsking = false
    @State private var showRename = false
    @State private var renameText = ""

    private var space: Space? { spaces.space(id: spaceID) }

    var body: some View {
        Group {
            if let space {
                content(space)
            } else {
                Text("Space not found")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
        .toolbar {
            if let space {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { app.newChatInSpace(spaceID: space.id) } label: {
                            Label("New chat in space", systemImage: "square.and.pencil")
                        }
                        Menu("Add meetings") {
                            ForEach(store.notes.prefix(50)) { note in
                                Button { spaces.toggle(noteID: note.id, in: space.id) } label: {
                                    Label { Text(note.title) } icon: {
                                        if space.noteIDs.contains(note.id) { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Rename and change icon") { renameText = space.name; showRename = true }
                        Divider()
                        Button("Delete space", role: .destructive) {
                            spaces.delete(id: space.id)
                            app.sidebar = .home
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showRename) {
            NewSpaceSheet(name: $renameText,
                          initialSymbol: spaces.space(id: spaceID)?.symbol ?? SpaceGlyph.defaultSymbol,
                          title: "Rename space",
                          confirmLabel: "Save") { name, symbol in
                spaces.rename(id: spaceID, to: name, symbol: symbol)
            }
        }
    }

    private func content(_ space: Space) -> some View {
        let meetings = space.noteIDs.compactMap { store.meta(id: $0) }.sorted { $0.createdAt > $1.createdAt }
        let spaceChats = app.askStore.sessions.filter { $0.spaceID == space.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    SpaceIcon(symbol: space.symbol, size: 26, color: .secondary)
                    Text(space.name)
                        .font(.system(size: 30, weight: .medium, design: .serif))
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
                Text(meetings.isEmpty ? "No meetings yet" : "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 18)

                if !spaceChats.isEmpty {
                    sectionHeader("Chats")
                    VStack(spacing: 1) {
                        ForEach(spaceChats) { session in
                            Button { app.openChatInWindow(sessionID: session.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Text(session.title)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(HomeRowButtonStyle())
                        }
                    }
                    .padding(.bottom, 8)
                }

                sectionHeader("Meetings")
                if meetings.isEmpty {
                    emptyMeetings
                } else {
                    VStack(spacing: 1) {
                        ForEach(meetings) { meta in
                            meetingRow(meta, space: space)
                        }
                    }
                }
                Color.clear.frame(height: 24)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 20)
        }
        .safeAreaInset(edge: .bottom) { askBar(space) }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meetingRow(_ meta: NoteMeta, space: Space) -> some View {
        Button { app.openNote(id: meta.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Text(meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HomeRowButtonStyle())
        .contextMenu {
            Button("Remove from space") { spaces.remove(noteID: meta.id, from: space.id) }
        }
    }

    private var emptyMeetings: some View {
        VStack(spacing: 8) {
            Text("No meetings in this space yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Use the menu in the top right to add meetings.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Scoped ask bar (mirrors Home)

    private func askBar(_ space: Space) -> some View {
        VStack(spacing: 10) {
            if let askAnswer {
                answerCard(askAnswer, space: space)
            }
            if let askError {
                Text(askError).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Ask about \(space.name)", text: $askText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit { runAsk(askText, space: space) }
                    if isAsking { ProgressView().controlSize(.small) }
                    ModelPickerMenu(agent: agent)
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)
            }
            .frame(maxWidth: 720)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private func answerCard(_ text: String, space: Space) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("In \(space.name)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !text.isEmpty {
                    Button { expandToChat(text, space: space) } label: {
                        Label("Open in chat", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    CopyButton(text: text, compact: true)
                }
                Button { askAnswer = nil; askError = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 6)
            ScrollView {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading this space").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                } else {
                    MarkdownView(text: text, textSize: 13)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            .frame(maxHeight: 220)
        }
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func expandToChat(_ answer: String, space: Space) {
        guard !answer.isEmpty else { return }
        let id = app.chat.startFrom(question: lastAsk, answer: answer, spaceID: space.id)
        askAnswer = nil
        askError = nil
        app.openChatInWindow(sessionID: id)
    }

    private func runAsk(_ question: String, space: Space) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isAsking else { return }
        lastAsk = q
        askText = ""
        isAsking = true
        askAnswer = ""
        askError = nil
        let meetings = space.noteIDs.compactMap { store.meta(id: $0) }
        Task {
            let context = meetings.map { ($0, store.loadSummary(noteID: $0.id)) }
            var streamed = ""
            do {
                let answer = try await agent.runStreaming(prompt: AgentPrompts.globalAsk(question: q, notes: context)) { delta in
                    streamed += delta
                    askAnswer = streamed
                }
                askAnswer = answer
            } catch {
                askAnswer = nil
                askError = error.localizedDescription
            }
            isAsking = false
        }
    }
}

// Sheet to name a space and pick its icon. Used for both create and rename.
struct NewSpaceSheet: View {
    @Binding var name: String
    var initialSymbol: String = SpaceGlyph.defaultSymbol
    var title: String = "New space"
    var confirmLabel: String = "Create"
    var action: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var symbol = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    private var chosen: String { symbol.isEmpty ? initialSymbol : symbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.record.opacity(0.14))
                    .frame(width: 46, height: 46)
                    .overlay(SpaceIcon(symbol: chosen, size: 22, color: Theme.record))
                TextField("Space name (Physics 101, Acme client, ...)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            }

            Text("Icon")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(SpaceSymbols.all, id: \.self) { sym in
                        let on = chosen == sym
                        Button { symbol = sym } label: {
                            Image(systemName: sym)
                                .font(.system(size: 16))
                                .foregroundStyle(on ? Theme.record : .primary.opacity(0.75))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(on ? Theme.record.opacity(0.14) : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(on ? Theme.record.opacity(0.9) : .clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 152)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                Button(confirmLabel) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            focused = true
            if symbol.isEmpty { symbol = initialSymbol }
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        action(trimmed, chosen)
        dismiss()
    }
}
