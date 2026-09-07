import SwiftUI
import AppKit

// Home: a persistent left rail (meetings + every chat), and a main pane that
// shows the notes list, an open note, or a selected conversation. Notes still
// push onto a NavigationStack like documents.
struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            // The companion column is NOT a split view with a collapsed
            // sidebar: the split view keeps live gesture machinery (edge
            // strips, swipe-to-reveal) that captures real trackpad scroll
            // sequences at this width, leaving every screen unscrollable.
            // Docked, the detail pane stands alone; the split view only
            // exists in the full window.
            if app.companionMode {
                detailPane
                    .toolbar { companionToggle }
            } else {
                // The toolbar must sit directly on the split view; attached to
                // the surrounding Group, non-NavigationStack screens (graph,
                // actions) lose their entire toolbar.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ChatSidebar()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
                } detail: {
                    detailPane
                }
                .toolbar { companionToggle }
            }
        }
        // Scrollbars show on every scrollable screen (Home, notes, action
        // items, chats); this propagates to all of them through the environment.
        .scrollIndicators(.visible)
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $updates.showSheet) {
            UpdateSheet(checker: updates)
        }
    }

    // Grows the docked companion column back into the full app, and shrinks
    // the full app to the side of the screen for a call. The knowledge graph
    // is a full-canvas screen, so the shrink offer fades out there (the item
    // itself must stay: a conditional or empty ToolbarItem tears down the
    // whole toolbar, taking every other screen's items with it). Expand still
    // shows if you arrive at the graph docked.
    private var companionToggle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if !app.companionMode && app.sidebar == .graph {
                // Real-but-invisible content, never an empty item: emptiness
                // tears the whole toolbar down, and an opacity-zero Button
                // still leaves its glass bezel as a ghost circle.
                Color.clear.frame(width: 1, height: 1)
            } else {
                Button {
                    WindowManager.shared.toggleCompanion(app: app)
                } label: {
                    Label(
                        app.companionMode ? "Expand" : "Shrink to the side",
                        systemImage: app.companionMode
                            ? "arrow.up.left.and.arrow.down.right"
                            : "arrow.down.right.and.arrow.up.left"
                    )
                }
                .help(app.companionMode ? "Expand to the full window" : "Dock a small window to the side")
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch app.sidebar {
        case .home:
            NavigationStack(path: $app.notePath) {
                HomeView()
                    .navigationDestination(for: UUID.self) { id in
                        // .id ties the view's state to the note. Without it, starting
                        // a meeting while another note is open reuses the old view and
                        // the new meeting shows the previous note's content.
                        NoteDetailView(noteID: id)
                            .id(id)
                    }
            }
        case .actions:
            ActionItemsView()
        case .graph:
            KnowledgeGraphView()
        case .chat, .noteChat:
            ChatConversationView(selection: app.sidebar)
        case .space(let id):
            SpaceView(spaceID: id)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var agent: AgentBridge
    @EnvironmentObject var calendar: CalendarManager
    @EnvironmentObject var spaces: SpaceStore

    @State private var searchText = ""
    @State private var askText = ""
    @State private var lastAsk = ""
    @State private var askAnswer: String?
    @State private var askError: String?
    @State private var isAsking = false
    @State private var noteToDelete: NoteMeta?
    @StateObject private var perms = Permissions()
    // Optional permissions can be waved away once the essentials are granted;
    // an essential going missing brings the banner back regardless.
    @AppStorage("permBannerHidden") private var permBannerHidden = false

    private var showPermissionsBanner: Bool {
        if perms.essentialsMissing { return true }
        if permBannerHidden { return false }
        return perms.screen != .granted || calendar.status == .notDetermined
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    EarshotLogoView(color: .primary, size: 26)
                    Text("Oats")
                        .font(.system(size: 30, weight: .medium, design: .serif))
                    Spacer()
                }
                .padding(.top, 20)
                .padding(.bottom, 18)

                if showPermissionsBanner {
                    PermissionsBanner(perms: perms) {
                        withAnimation { permBannerHidden = true }
                    }
                    .padding(.bottom, 18)
                }

                if recorder.isActive, let liveID = recorder.currentNoteID {
                    liveCard(liveID)
                        .padding(.bottom, 20)
                }

                if calendar.showUpcoming && !recorder.isActive {
                    ComingUpCard()
                        .padding(.bottom, 8)
                }

                if !searchText.isEmpty {
                    searchResults
                } else if store.notes.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedNotes, id: \.0) { day, notes in
                        Text(day)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                        VStack(spacing: 1) {
                            ForEach(notes) { meta in
                                noteRow(meta)
                            }
                        }
                    }
                }
                Color.clear.frame(height: 30)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .background(Theme.windowBG)
        .searchable(text: $searchText, prompt: "Search notes")
        .safeAreaInset(edge: .bottom) { askBar }
        .alert(
            "Delete \"\(noteToDelete?.title ?? "this note")\"?",
            isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let note = noteToDelete { store.deleteNote(id: note.id) }
                noteToDelete = nil
            }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        } message: {
            Text("The recording, transcript and summary go with it. This cannot be undone.")
        }
    }

    // MARK: - Live recording card

    private func liveCard(_ id: UUID) -> some View {
        Button {
            app.openNote(id: id)
        } label: {
            HStack(spacing: 12) {
                WaveformBars(levels: recorder.levels, barColor: Theme.record, barCount: 9, maxHeight: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.meta(id: id)?.title ?? "New note")
                        .font(.system(size: 14, weight: .semibold))
                    Text(recorder.isPaused ? "Paused" : "Listening")
                        .font(.system(size: 12))
                        .foregroundStyle(recorder.isPaused ? Color.secondary : Theme.record)
                }
                Spacer()
                Text(recorder.elapsed.clockString)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Rows

    private func noteRow(_ meta: NoteMeta) -> some View {
        Button {
            app.openNote(id: meta.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Text(meta.duration > 0 ? "Me · \(meta.duration.clockString)" : "Me")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(meta.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HomeRowButtonStyle())
        .contextMenu {
            if !spaces.spaces.isEmpty {
                Menu("Add to space") {
                    ForEach(spaces.spaces) { space in
                        Button {
                            spaces.toggle(noteID: meta.id, in: space.id)
                        } label: {
                            Label {
                                Text(space.name)
                            } icon: {
                                if space.noteIDs.contains(meta.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Divider()
            }
            Button("Reveal files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.dir(for: meta.id)])
            }
            Divider()
            Button("Delete note", role: .destructive) {
                noteToDelete = meta
            }
        }
    }

    // MARK: - Semantic search results

    @ViewBuilder
    private var searchResults: some View {
        let results = SemanticIndex.shared.search(searchText, in: store)
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matches")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                Text("Nothing in your meetings matches that yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            Text("Best matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 6)
            VStack(spacing: 1) {
                ForEach(results) { result in
                    if let meta = store.meta(id: result.noteID) {
                        searchRow(meta, snippet: result.snippet)
                    }
                }
            }
        }
    }

    private func searchRow(_ meta: NoteMeta, snippet: String) -> some View {
        Button { app.openNote(id: meta.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(meta.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(meta.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    if !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HomeRowButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.system(size: 15, weight: .semibold, design: .serif))
            Text("Press New note before your next meeting. Oats transcribes both sides on this Mac and writes the summary for you.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: - Floating ask bar

    private var askBar: some View {
        VStack(spacing: 10) {
            if let askAnswer {
                answerCard(askAnswer)
            }
            if let askError {
                Text(askError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Ask anything across your meetings", text: $askText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .onSubmit { runAsk(askText) }
                        if isAsking {
                            ProgressView().controlSize(.small)
                        }
                        ModelPickerMenu(agent: agent)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)

                    Button {
                        // Opens the hub. It never re-extracts or duplicates:
                        // items are written once per meeting, this just shows them.
                        app.sidebar = .actions
                    } label: {
                        Label("Action items", systemImage: "checklist")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .fixedSize()
                    .help("See every action item from your meetings")
                }
            }
            .frame(maxWidth: 720)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private func answerCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("From your meetings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !text.isEmpty {
                    Button { expandToChat(text) } label: {
                        Label("Open in chat", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Continue this as a full chat")
                    CopyButton(text: text, compact: true)
                }
                Button {
                    askAnswer = nil
                    askError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
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
                        Text("Reading your recent meetings")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                } else {
                    MarkdownView(text: text, textSize: 13)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
            .frame(maxHeight: 220)
        }
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Data

    private var filteredNotes: [NoteMeta] {
        guard !searchText.isEmpty else { return store.notes }
        let q = searchText.lowercased()
        return store.notes.filter { meta in
            meta.title.lowercased().contains(q)
                || store.loadSummary(noteID: meta.id).lowercased().contains(q)
                || store.loadThoughts(noteID: meta.id).lowercased().contains(q)
        }
    }

    private var groupedNotes: [(String, [NoteMeta])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredNotes) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            let label = calendar.isDateInToday(day) ? "Today" : (calendar.isDateInYesterday(day) ? "Yesterday" : formatter.string(from: day))
            return (label, groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    // Promote the quick Home answer into a real, continuable chat window.
    private func expandToChat(_ answer: String) {
        guard !answer.isEmpty else { return }
        let id = app.chat.startFrom(question: lastAsk, answer: answer)
        askAnswer = nil
        askError = nil
        app.openChatInWindow(sessionID: id)
    }

    private func runAsk(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isAsking else { return }
        lastAsk = q
        askText = ""
        isAsking = true
        askAnswer = ""   // show the card immediately; fill it as tokens arrive
        askError = nil
        Task {
            let context = store.notes.prefix(10).map { ($0, store.loadSummary(noteID: $0.id)) }
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

// "Coming up": today's meetings from the native calendar, one click to record.
struct ComingUpCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var calendar: CalendarManager
    @EnvironmentObject var recorder: MeetingRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 0) {
                    Text(Date().formatted(.dateTime.day()))
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    Text(Date().formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40)

                switch calendar.status {
                case .notDetermined:
                    Text("See today's meetings here and start a note for one with a single click.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect calendar") { calendar.connect() }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                case .denied:
                    Text("Calendar access is off. Turn it on to see your meetings here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open settings") { calendar.openSystemSettings() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                case .authorized:
                    if calendar.upcoming.isEmpty {
                        Text("No more meetings today.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if calendar.status == .authorized && !calendar.upcoming.isEmpty {
                Divider().opacity(0.4)
                VStack(spacing: 0) {
                    ForEach(calendar.upcoming, id: \.eventIdentifier) { event in
                        HStack(spacing: 11) {
                            Circle()
                                .fill(Color(nsColor: event.calendar?.color ?? .systemGray))
                                .frame(width: 7, height: 7)
                            Text(timeLabel(event.startDate))
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 66, alignment: .leading)
                            Text(event.title ?? "Untitled event")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            let link = MeetingLink.detect(in: event)
                            Button {
                                // If the event carries a Zoom/Meet/Teams link, open
                                // the call, then start the note. No link: just record.
                                if let link { NSWorkspace.shared.open(link) }
                                app.startMeetingNote(title: event.title)
                            } label: {
                                Label(link != nil ? "Join & Record" : "Record",
                                      systemImage: link != nil ? "video.fill" : "record.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .tint(link != nil ? Theme.record : nil)
                            .help(link != nil ? "Open \(MeetingLink.providerName(for: link!)) and start recording" : "Start recording")
                            .disabled(recorder.isActive)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                }
                .padding(.bottom, 5)
            }
        }
        .card(radius: 16)
    }

    // "Now" while the meeting is happening, a plain time today, and an explicit
    // day for anything further out, so a row never looks like a stale ghost.
    private func timeLabel(_ start: Date) -> String {
        if start <= Date() { return "Now" }
        let time = start.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(start) { return time }
        if Calendar.current.isDateInTomorrow(start) { return "Tomorrow " + time }
        return start.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }
}

struct HomeRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(configuration.isPressed ? 0.7 : (hovering ? 0.45 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

// Render simple markdown without heavy dependencies.
func markdownish(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
