import SwiftUI
import AppKit

// Home: one calm dark canvas, notes grouped by day, a floating ask bar.
// Notes push onto a NavigationStack like documents, not master-detail panes.
struct MainWindowView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack(path: $app.notePath) {
            HomeView()
                .navigationDestination(for: UUID.self) { id in
                    NoteDetailView(noteID: id)
                }
        }
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var agent: AgentBridge
    @EnvironmentObject var calendar: CalendarManager

    @State private var searchText = ""
    @State private var askText = ""
    @State private var askAnswer: String?
    @State private var askError: String?
    @State private var isAsking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notes")
                    .font(.system(size: 30, weight: .medium, design: .serif))
                    .padding(.top, 20)
                    .padding(.bottom, 18)

                if recorder.isActive, let liveID = recorder.currentNoteID {
                    liveCard(liveID)
                        .padding(.bottom, 20)
                }

                if calendar.showUpcoming && !recorder.isActive {
                    ComingUpCard()
                        .padding(.bottom, 8)
                }

                if store.notes.isEmpty {
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
        .safeAreaInset(edge: .bottom) { askBar }
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
            Button("Reveal files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.dir(for: meta.id)])
            }
            Divider()
            Button("Delete note", role: .destructive) {
                store.deleteNote(id: meta.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.system(size: 15, weight: .semibold, design: .serif))
            Text("Press New note before your next meeting. Earshot transcribes both sides on this Mac and writes the summary for you.")
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
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)

                    Button {
                        runAsk("List the open action items from my recent meetings, grouped by meeting.")
                    } label: {
                        Label("Action items", systemImage: "checklist")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(isAsking)
                    .fixedSize()
                    .help("Pull open action items from your recent notes")
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
            HStack {
                Text("From your meetings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
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
                Text(markdownish(text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
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

    private func runAsk(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isAsking else { return }
        askText = ""
        isAsking = true
        askAnswer = nil
        askError = nil
        Task {
            let context = store.notes.prefix(10).map { ($0, store.loadSummary(noteID: $0.id)) }
            do {
                askAnswer = try await agent.run(prompt: AgentPrompts.globalAsk(question: q, notes: context))
            } catch {
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
                        .controlSize(.large)
                case .denied:
                    Text("Calendar access is off. Turn it on to see your meetings here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open settings") { calendar.openSystemSettings() }
                        .buttonStyle(.glass)
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
                            Text(event.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 66, alignment: .leading)
                            Text(event.title ?? "Untitled event")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                app.startMeetingNote(title: event.title)
                            } label: {
                                Label("Record", systemImage: "record.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.glass)
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
