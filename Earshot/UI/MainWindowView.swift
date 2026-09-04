import SwiftUI
import AppKit

// Native macOS structure: sidebar of notes (Apple Notes pattern), detail is
// the note itself. Liquid Glass comes from native components and toolbars.
struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if let id = app.selectedNoteID, store.meta(id: id) != nil {
                NoteDetailView(noteID: id)
                    .id(id)
            } else {
                WelcomePane()
            }
        }
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
    }

    private var sidebar: some View {
        List(selection: $app.selectedNoteID) {
            ForEach(groupedNotes, id: \.0) { day, notes in
                Section(day) {
                    ForEach(notes) { meta in
                        NoteRow(meta: meta, isLive: recorder.isActive && recorder.currentNoteID == meta.id)
                            .tag(meta.id)
                            .contextMenu {
                                Button("Reveal files in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([store.dir(for: meta.id)])
                                }
                                Divider()
                                Button("Delete note", role: .destructive) {
                                    if app.selectedNoteID == meta.id { app.selectedNoteID = nil }
                                    store.deleteNote(id: meta.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes")
        .overlay {
            if store.notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No notes yet")
                        .font(.headline)
                    Text("Start a recording before your next meeting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .toolbar {
            ToolbarItem {
                if recorder.isActive {
                    Button {
                        app.showCurrentNoteWindow()
                    } label: {
                        Label(recorder.elapsed.clockString, systemImage: "waveform")
                            .foregroundStyle(Theme.record)
                    }
                    .help("Recording in progress")
                } else {
                    Button {
                        app.startMeetingNote()
                    } label: {
                        Label("New note", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .help("Start a meeting note  Opt+M")
                }
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
    }

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
}

struct NoteRow: View {
    let meta: NoteMeta
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(meta.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLive {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.record)
            }
        }
        .padding(.vertical, 2)
    }
}

// Shown when no note is selected: global ask over all meetings.
struct WelcomePane: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var agent: AgentBridge

    @State private var askText = ""
    @State private var answer: String?
    @State private var errorText: String?
    @State private var isAsking = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Earshot")
                .font(.system(size: 24, weight: .semibold))
            Text("Meeting notes that never leave your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let answer {
                ScrollView {
                    Text(markdownish(answer))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxWidth: 520, maxHeight: 240)
                .card()
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 8) {
                TextField("Ask across your meetings", text: $askText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onSubmit { runAsk() }
                if isAsking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .frame(maxWidth: 460)
            .glassEffect(.regular, in: .capsule)

            Spacer()
            Text("Opt+M starts a note from anywhere.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
    }

    private func runAsk() {
        let question = askText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !isAsking else { return }
        isAsking = true
        answer = nil
        errorText = nil
        Task {
            let context = store.notes.prefix(10).map { ($0, store.loadSummary(noteID: $0.id)) }
            do {
                answer = try await agent.run(prompt: AgentPrompts.globalAsk(question: question, notes: context))
            } catch {
                errorText = error.localizedDescription
            }
            isAsking = false
        }
    }
}

// Render simple markdown without heavy dependencies.
func markdownish(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
