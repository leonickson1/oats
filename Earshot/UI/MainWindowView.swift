import SwiftUI
import AppKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case notetaker, dictation, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .notetaker: return "Notetaker"
        case .dictation: return "Dictation"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .notetaker: return "record.circle"
        case .dictation: return "mic"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @State private var selection: SidebarItem = .notetaker

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.hairline)
            Group {
                switch selection {
                case .notetaker: NotetakerPage()
                case .dictation: DictationPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.windowBG)
        }
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                Text("Earshot")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.top, 44)
            .padding(.bottom, 18)

            ForEach([SidebarItem.dictation, .notetaker]) { item in
                sidebarRow(item)
            }

            Spacer()

            sidebarRow(.settings)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBG)
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(item.label)
                    .font(.system(size: 13.5, weight: selection == item ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selection == item ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selection == item ? Theme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notetaker page

struct NotetakerPage: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var agent: AgentBridge

    @State private var selectedNoteID: UUID?
    @State private var askText = ""
    @State private var askAnswer: String?
    @State private var askError: String?
    @State private var isAsking = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                askBar
                if let askAnswer, !askAnswer.isEmpty {
                    answerCard(askAnswer)
                }
                if let askError {
                    Text(askError)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.destructive)
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                }
                notesList
            }
            .frame(maxWidth: .infinity)

            if let id = selectedNoteID, let meta = store.meta(id: id) {
                previewPane(meta: meta)
                    .frame(width: 300)
                    .padding(.trailing, 24)
                    .padding(.top, 90)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Notetaker")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            if recorder.isActive {
                Button {
                    app.showCurrentNoteWindow()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                        Text("Recording \(recorder.elapsed.clockString)")
                    }
                }
                .buttonStyle(PillButtonStyle())
            }
            Button {
                app.startMeetingNote()
            } label: {
                Label("New note", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(recorder.isActive)
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .padding(.bottom, 18)
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            TextField("Ask about your meetings", text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .onSubmit { runGlobalAsk() }
            if isAsking {
                ProgressView().controlSize(.small)
            } else if askAnswer != nil || askError != nil {
                Button {
                    askAnswer = nil
                    askError = nil
                    askText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairlineCard(radius: 22)
        .padding(.horizontal, 28)
    }

    private func answerCard(_ text: String) -> some View {
        ScrollView {
            Text(markdownish(text))
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(maxHeight: 200)
        .hairlineCard()
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    private var notesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                Text("My notes")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 10)

                if store.notes.isEmpty {
                    VStack(spacing: 10) {
                        Text("No notes yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                        Text("Press New note before your next meeting. Earshot transcribes both sides on this Mac and writes the summary for you.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(groupedNotes, id: \.0) { day, notes in
                        Text(day)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(notes) { meta in
                            noteRow(meta)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 30)
        }
    }

    private func noteRow(_ meta: NoteMeta) -> some View {
        Button {
            selectedNoteID = meta.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(meta.createdAt.formatted(date: .omitted, time: .shortened).lowercased())
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if recorder.isActive && recorder.currentNoteID == meta.id {
                    Text("Recording")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.recordGreen)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(selectedNoteID == meta.id ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { app.openNote(id: meta.id) })
        .contextMenu {
            Button("Open note") { app.openNote(id: meta.id) }
            Button("Reveal files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.dir(for: meta.id)])
            }
            Divider()
            Button("Delete note", role: .destructive) {
                if selectedNoteID == meta.id { selectedNoteID = nil }
                store.deleteNote(id: meta.id)
            }
        }
    }

    private func previewPane(meta: NoteMeta) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meta.title)
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
            Button("Open note") { app.openNote(id: meta.id) }
                .buttonStyle(PillButtonStyle())
            let summary = store.loadSummary(noteID: meta.id)
            if !summary.isEmpty {
                ScrollView {
                    Text(markdownish(summary))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(meta.hasSummary ? "" : "No summary yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBG)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var groupedNotes: [(String, [NoteMeta])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: store.notes) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            let label = calendar.isDateInToday(day) ? "Today" : (calendar.isDateInYesterday(day) ? "Yesterday" : formatter.string(from: day))
            return (label, groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private func runGlobalAsk() {
        let question = askText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !isAsking else { return }
        isAsking = true
        askAnswer = nil
        askError = nil
        Task {
            let context = store.notes.prefix(10).map { ($0, store.loadSummary(noteID: $0.id)) }
            do {
                let answer = try await agent.run(prompt: AgentPrompts.globalAsk(question: question, notes: context))
                askAnswer = answer
            } catch {
                askError = error.localizedDescription
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
