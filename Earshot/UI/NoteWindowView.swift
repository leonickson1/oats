import SwiftUI
import AppKit

enum NoteTab: String, CaseIterable {
    case thoughts = "My thoughts"
    case transcript = "Transcript"
    case summary = "Summary"
}

struct NoteWindowView: View {
    let noteID: UUID

    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var agent: AgentBridge

    @State private var tab: NoteTab = .transcript
    @State private var title = ""
    @State private var thoughts = ""
    @State private var chat: [ChatMessage] = []
    @State private var askText = ""
    @State private var isAsking = false
    @State private var loaded = false
    @State private var savedSegments: [TranscriptSegment] = []

    private var isLiveNote: Bool { recorder.isActive && recorder.currentNoteID == noteID }

    private var displayedSegments: [TranscriptSegment] {
        isLiveNote ? recorder.segments : savedSegments
    }

    var body: some View {
        VStack(spacing: 0) {
            titleArea
            tabBar
            Divider().overlay(Theme.hairline).padding(.horizontal, 24)

            Group {
                switch tab {
                case .thoughts: thoughtsTab
                case .transcript: transcriptTab
                case .summary: summaryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !chat.isEmpty {
                chatSection
            }
            bottomBar
        }
        .background(Theme.windowBG)
        .ignoresSafeArea()
        .onAppear(perform: load)
        .onChange(of: store.revision) { reload() }
        .onChange(of: thoughts) {
            guard loaded else { return }
            store.saveThoughts(noteID: noteID, thoughts)
        }
        .onChange(of: title) {
            guard loaded, var meta = store.meta(id: noteID), meta.title != title, !title.isEmpty else { return }
            meta.title = title
            store.save(meta: meta)
        }
    }

    // MARK: - Loading

    private func load() {
        guard !loaded else { return }
        title = store.meta(id: noteID)?.title ?? "New note"
        thoughts = store.loadThoughts(noteID: noteID)
        chat = store.loadChat(noteID: noteID)
        savedSegments = store.loadSegments(noteID: noteID)
        if isLiveNote { tab = .transcript }
        else if store.meta(id: noteID)?.hasSummary == true { tab = .summary }
        loaded = true
    }

    private func reload() {
        guard loaded else { return }
        if !isLiveNote { savedSegments = store.loadSegments(noteID: noteID) }
        if let meta = store.meta(id: noteID), meta.title != title { title = meta.title }
    }

    // MARK: - Title

    private var titleArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("New note", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .medium, design: .serif))
                .foregroundStyle(title == "New note" ? Theme.tertiary : Theme.ink)
            if let meta = store.meta(id: noteID) {
                Text(meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 44)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(NoteTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 5) {
                            if t == .transcript && isLiveNote {
                                WaveformBars(levels: recorder.levels, barColor: Theme.recordGreen, barCount: 4)
                                    .frame(width: 14, height: 11)
                            }
                            Text(t.rawValue)
                                .font(.system(size: 14, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? Theme.ink : Theme.secondary)
                        }
                        Rectangle()
                            .fill(tab == t ? Theme.ink : Color.clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 8)
    }

    // MARK: - Tabs

    private var thoughtsTab: some View {
        TextEditor(text: $thoughts)
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            .background(Theme.windowBG)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .topLeading) {
                if thoughts.isEmpty {
                    Text("Type anything. Earshot keeps listening and takes the notes for you.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 26)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sessionHeader
                    if displayedSegments.isEmpty && recorder.volatileMe.isEmpty && recorder.volatileThem.isEmpty {
                        if isLiveNote {
                            Text("Listening")
                                .font(.system(size: 15, design: .serif))
                                .italic()
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 90)
                        } else {
                            Text("No transcript was captured.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 90)
                        }
                    } else {
                        ForEach(displayedSegments) { segment in
                            segmentRow(segment)
                        }
                        if isLiveNote {
                            if !recorder.volatileThem.isEmpty {
                                volatileRow(channel: "them", text: recorder.volatileThem)
                            }
                            if !recorder.volatileMe.isEmpty {
                                volatileRow(channel: "me", text: recorder.volatileMe)
                            }
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .onChange(of: recorder.segments.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    private var sessionHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Text(isLiveNote ? recorder.elapsed.clockString : (store.meta(id: noteID)?.duration ?? 0).clockString)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                Spacer()
                Button {
                    let text = displayedSegments.map { "[\($0.t.clockString)] \($0.channel == "me" ? "Me" : "Them"): \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy transcript")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if isLiveNote {
                HStack {
                    Text(recorder.systemAudioUnavailable
                         ? "System audio is off, so only your mic is transcribed. Allow System Audio Recording in Privacy & Security."
                         : "Transcribing on this Mac. Speakers are labeled after the meeting. Nothing leaves your device.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.sidebarBG)
            }
        }
        .hairlineCard(radius: 12)
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(segment.channel == "me" ? "Me" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text(segment.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func volatileRow(channel: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(channel == "me" ? "Me" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let summary = store.loadSummary(noteID: noteID)
                if recorder.isSummarizing && (isLiveNote || recorder.currentNoteID == nil) && summary.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing the summary with \(agent.activeAgentName)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                } else if summary.isEmpty {
                    VStack(spacing: 8) {
                        Text(isLiveNote ? "The summary is written when you stop." : "No summary yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiary)
                        if !isLiveNote && !displayedSegments.isEmpty {
                            Button("Generate summary") {
                                Task { await recorder.generateSummary(noteID: noteID) }
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(markdownish(summary))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(3)
                    if !isLiveNote {
                        Button("Regenerate") {
                            Task { await recorder.generateSummary(noteID: noteID) }
                        }
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, 6)
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(chat) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role == "user" ? "You" : "Assistant")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                            Text(markdownish(message.text))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }
                    if isAsking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking \(agent.activeAgentName)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .padding(14)
            }
            .frame(height: 180)
            .hairlineCard(radius: 12)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .onChange(of: chat.count) {
                if let last = chat.last { withAnimation { proxy.scrollTo(last.id) } }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 9) {
            Text("Always get consent when transcribing others.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
            HStack(spacing: 9) {
                if isLiveNote {
                    Button {
                        app.stopMeetingNote()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.recordGreen)
                            Text("Stop")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.card)
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    TextField("Ask anything", text: $askText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                        .onSubmit { ask(askText) }
                    Button {
                        ask("What did I miss?")
                    } label: {
                        Text("What did I miss?")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Theme.sidebarBG)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAsking)
                }
                .padding(.leading, 16)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(Theme.card)
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isAsking else { return }
        askText = ""
        let userMessage = ChatMessage(role: "user", text: q)
        chat.append(userMessage)
        store.appendChat(noteID: noteID, userMessage)
        isAsking = true
        Task {
            let segments = displayedSegments
            let prompt: String
            if q == "What did I miss?" && isLiveNote {
                prompt = AgentPrompts.whatDidIMiss(segments: segments)
            } else {
                prompt = AgentPrompts.chat(
                    question: q,
                    segments: segments,
                    thoughts: thoughts,
                    summary: store.loadSummary(noteID: noteID)
                )
            }
            do {
                let answer = try await agent.run(prompt: prompt)
                let reply = ChatMessage(role: "assistant", text: answer)
                chat.append(reply)
                store.appendChat(noteID: noteID, reply)
            } catch {
                chat.append(ChatMessage(role: "assistant", text: error.localizedDescription))
            }
            isAsking = false
        }
    }
}
