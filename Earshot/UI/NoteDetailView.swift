import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NoteTab: String, CaseIterable {
    case thoughts = "My thoughts"
    case transcript = "Transcript"
    case summary = "Summary"
}

struct NoteDetailView: View {
    let noteID: UUID

    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var agent: AgentBridge
    @EnvironmentObject var capture: CaptureManager

    @State private var tab: NoteTab = .transcript
    @State private var title = ""
    @State private var thoughts = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var attachments: [Attachment] = []
    @State private var chat: [ChatMessage] = []
    @State private var askText = ""
    @State private var isAsking = false
    @State private var loaded = false
    @State private var savedSegments: [TranscriptSegment] = []
    @State private var showLinkPrompt = false
    @State private var linkText = ""
    @State private var showImagePicker = false
    @State private var saveDebounce: Task<Void, Never>?

    private var isLiveNote: Bool { recorder.isActive && recorder.currentNoteID == noteID }
    private var displayedSegments: [TranscriptSegment] { isLiveNote ? recorder.segments : savedSegments }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.5)

            Group {
                switch tab {
                case .thoughts: thoughtsTab
                case .transcript: TranscriptPane(
                    segments: displayedSegments,
                    isLive: isLiveNote,
                    isPaused: recorder.isPaused,
                    volatileMe: isLiveNote ? recorder.volatileMe : "",
                    volatileThem: isLiveNote ? recorder.volatileThem : "",
                    elapsed: isLiveNote ? recorder.elapsed : (store.meta(id: noteID)?.duration ?? 0),
                    systemAudioUnavailable: recorder.systemAudioUnavailable,
                    canGenerateSummary: !isLiveNote && store.loadSummary(noteID: noteID).isEmpty && !displayedSegments.isEmpty && !recorder.isSummarizing,
                    onGenerateSummary: {
                        tab = .summary
                        Task { await recorder.generateSummary(noteID: noteID) }
                    }
                )
                case .summary: summaryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !chat.isEmpty { chatSection }
        }
        .background(Theme.windowBG)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear(perform: load)
        .onChange(of: store.revision) { reload() }
        .onChange(of: thoughts) { scheduleSave() }
        .onChange(of: title) {
            guard loaded, var meta = store.meta(id: noteID), meta.title != title, !title.isEmpty else { return }
            meta.title = title
            meta.titleLocked = true
            store.save(meta: meta)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        _ = await capture.captureRegion(noteID: noteID, at: isLiveNote ? recorder.elapsed : 0)
                        attachments = store.loadAttachments(noteID: noteID)
                    }
                } label: {
                    Label("Capture screen", systemImage: "camera.viewfinder")
                }
                .disabled(capture.isCapturing)
                .help("Capture part of the screen into this note (slides, charts, whiteboards)")
            }
            ToolbarItem {
                Menu {
                    Button("Reveal files in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.dir(for: noteID)])
                    }
                    Button("Copy transcript") {
                        let text = displayedSegments.filter { $0.channel != "system" }
                            .map { "[\($0.t.clockString)] \($0.channel == "me" ? "Me" : "Them"): \($0.text)" }
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Divider()
                    Button("Delete note", role: .destructive) {
                        app.notePath = []
                        store.deleteNote(id: noteID)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .alert("Add link", isPresented: $showLinkPrompt) {
            TextField("https://", text: $linkText)
            Button("Add") {
                capture.addLink(noteID: noteID, urlString: linkText, at: isLiveNote ? recorder.elapsed : 0)
                linkText = ""
                attachments = store.loadAttachments(noteID: noteID)
            }
            Button("Cancel", role: .cancel) { linkText = "" }
        }
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                capture.addImage(noteID: noteID, from: url, at: isLiveNote ? recorder.elapsed : 0)
                if scoped { url.stopAccessingSecurityScopedResource() }
                attachments = store.loadAttachments(noteID: noteID)
            }
        }
    }

    // MARK: - Loading / saving

    private func load() {
        guard !loaded else { return }
        let meta = store.meta(id: noteID)
        title = meta?.title ?? "New note"
        thoughts = store.loadRichThoughts(noteID: noteID)
        chat = store.loadChat(noteID: noteID)
        attachments = store.loadAttachments(noteID: noteID)
        savedSegments = store.loadSegments(noteID: noteID)
        if isLiveNote { tab = .transcript }
        else if meta?.hasSummary == true { tab = .summary }
        loaded = true
    }

    private func reload() {
        guard loaded else { return }
        if !isLiveNote { savedSegments = store.loadSegments(noteID: noteID) }
        attachments = store.loadAttachments(noteID: noteID)
        if let meta = store.meta(id: noteID), meta.title != title { title = meta.title }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveDebounce?.cancel()
        let snapshot = thoughts
        saveDebounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.saveThoughts(noteID: noteID, snapshot)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("New note", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .medium, design: .serif))
                .foregroundStyle(store.meta(id: noteID)?.isUntitled == true ? Color.secondary : Color.primary)
                .lineLimit(2)

            HStack(spacing: 7) {
                if let meta = store.meta(id: noteID) {
                    MetaChip(icon: "calendar", text: chipDate(meta.createdAt))
                }
                let duration = isLiveNote ? recorder.elapsed : (store.meta(id: noteID)?.duration ?? 0)
                if duration > 0 || isLiveNote {
                    MetaChip(icon: "clock", text: duration.clockString)
                }
                if isLiveNote {
                    if recorder.state == .starting {
                        MetaChip(icon: "waveform", text: "Preparing")
                    } else if recorder.isPaused {
                        MetaChip(icon: "pause.fill", text: "Paused")
                    } else {
                        MetaChip(icon: "waveform", text: "Listening", tint: Theme.record)
                    }
                } else if recorder.isSummarizing {
                    MetaChip(icon: "brain", text: "Summarizing")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Underline tabs

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(NoteTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            if t == .transcript && isLiveNote && !recorder.isPaused {
                                WaveformBars(levels: recorder.levels, barColor: Theme.record, barCount: 4, maxHeight: 10)
                            }
                            Text(t.rawValue)
                                .font(.system(size: 14, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        }
                        Rectangle()
                            .fill(tab == t ? Color.primary : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Thoughts

    private var thoughtsTab: some View {
        VStack(spacing: 0) {
            RichTextToolbar(text: $thoughts, selection: $selection) {
                showLinkPrompt = true
            } onAttachImage: {
                showImagePicker = true
            } onCapture: {
                Task {
                    _ = await capture.captureRegion(noteID: noteID, at: isLiveNote ? recorder.elapsed : 0)
                    attachments = store.loadAttachments(noteID: noteID)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            TextEditor(text: $thoughts, selection: $selection)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .overlay(alignment: .topLeading) {
                    if thoughts.characters.isEmpty {
                        Text("Write notes, or drop in a capture. Earshot keeps listening either way.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 25)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            if !attachments.isEmpty {
                AttachmentStrip(noteID: noteID, attachments: $attachments)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(url.pathExtension.lowercased()) {
                capture.addImage(noteID: noteID, from: url, at: isLiveNote ? recorder.elapsed : 0)
                added = true
            }
            if added { attachments = store.loadAttachments(noteID: noteID) }
            return added
        }
    }

    // MARK: - Summary

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let summary = store.loadSummary(noteID: noteID)
                if recorder.isSummarizing && summary.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing the summary with \(agent.activeAgentName)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 70)
                    .frame(maxWidth: .infinity)
                } else if summary.isEmpty {
                    VStack(spacing: 14) {
                        Text(isLiveNote ? "The summary is written when you stop." : "No summary yet.")
                            .font(.system(size: 14, design: .serif))
                            .italic()
                            .foregroundStyle(.tertiary)
                        if !isLiveNote && !displayedSegments.isEmpty {
                            Button {
                                Task { await recorder.generateSummary(noteID: noteID) }
                            } label: {
                                Label("Generate summary", systemImage: "plus")
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                    .padding(.top, 70)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(markdownish(summary))
                        .font(.system(size: 13.5))
                        .textSelection(.enabled)
                        .lineSpacing(3.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !isLiveNote {
                        Button("Regenerate") {
                            Task { await recorder.generateSummary(noteID: noteID) }
                        }
                        .buttonStyle(.glass)
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
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
                                .foregroundStyle(.tertiary)
                            Text(markdownish(message.text))
                                .font(.system(size: 13))
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
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(14)
            }
            .frame(height: 160)
            .card()
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
            .onChange(of: chat.count) {
                if let last = chat.last { withAnimation { proxy.scrollTo(last.id) } }
            }
        }
    }

    // MARK: - Floating bottom bar

    private var bottomBar: some View {
        VStack(spacing: 7) {
            Text("Always get consent when transcribing others.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if isLiveNote {
                        if recorder.isPaused {
                            Button {
                                recorder.resume()
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "record.circle")
                                        .foregroundStyle(Theme.record)
                                    Text("Resume")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        } else {
                            Button {
                                recorder.pause()
                            } label: {
                                Image(systemName: "pause.fill")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .help("Pause")

                            Button {
                                app.stopMeetingNote()
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "stop.fill")
                                        .foregroundStyle(Theme.record)
                                    Text("Stop")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .help("Stop and summarize")
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Ask anything", text: $askText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .onSubmit { ask(askText) }
                        if isAsking {
                            ProgressView().controlSize(.small)
                        } else if isLiveNote {
                            Button {
                                ask("What did I miss?")
                            } label: {
                                Text("What did I miss?")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .frame(height: 42)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .frame(maxWidth: 680)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .padding(.top, 4)
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
            let segments = displayedSegments.filter { $0.channel != "system" }
            let prompt: String
            if q == "What did I miss?" && isLiveNote {
                prompt = AgentPrompts.whatDidIMiss(segments: segments)
            } else {
                prompt = AgentPrompts.chat(
                    question: q,
                    segments: segments,
                    thoughts: String(thoughts.characters),
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

// MARK: - Transcript pane (bubble style)

struct TranscriptPane: View {
    let segments: [TranscriptSegment]
    let isLive: Bool
    let isPaused: Bool
    let volatileMe: String
    let volatileThem: String
    let elapsed: TimeInterval
    let systemAudioUnavailable: Bool
    let canGenerateSummary: Bool
    let onGenerateSummary: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sessionCard
                    if segments.isEmpty && volatileMe.isEmpty && volatileThem.isEmpty {
                        Text(isLive ? "Listening..." : "No transcript was captured.")
                            .font(.system(size: 16, design: .serif))
                            .italic()
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 90)
                    } else {
                        bubbles
                        if isPaused {
                            DashedMarker(label: "Paused", icon: "pause")
                        }
                        if canGenerateSummary {
                            HStack {
                                Spacer()
                                Button(action: onGenerateSummary) {
                                    Label("Generate summary", systemImage: "plus")
                                }
                                .buttonStyle(.glassProminent)
                                Spacer()
                            }
                            .padding(.top, 14)
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .onChange(of: segments.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    private var sessionCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(elapsed.clockString)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if isLive {
                HStack {
                    Text(systemAudioUnavailable
                         ? "System audio is off; only your mic is heard. Allow System Audio Recording in Privacy & Security."
                         : "Transcribing on this Mac. Nothing leaves your device.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))
            }
        }
        .card(radius: 12)
        .padding(.bottom, 8)
    }

    private var bubbles: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if segment.channel == "system" {
                    DashedMarker(label: segment.text, icon: segment.text == "Paused" ? "pause" : "play")
                } else {
                    if speakerChanged(at: index) {
                        Text(segment.channel == "me" ? "Me" : "Them")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(segment.channel == "me" ? Color.secondary : Theme.record)
                            .padding(.top, index == 0 ? 0 : 8)
                            .padding(.leading, 2)
                    }
                    bubble(segment.text, dim: false)
                }
            }
            if isLive && !volatileThem.isEmpty {
                bubble(volatileThem, dim: true)
            }
            if isLive && !volatileMe.isEmpty {
                bubble(volatileMe, dim: true)
            }
        }
    }

    private func speakerChanged(at index: Int) -> Bool {
        let spoken = segments
        guard index < spoken.count else { return false }
        let current = spoken[index].channel
        var previousIndex = index - 1
        while previousIndex >= 0, spoken[previousIndex].channel == "system" { previousIndex -= 1 }
        guard previousIndex >= 0 else { return true }
        return spoken[previousIndex].channel != current
    }

    private func bubble(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(dim ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .lineSpacing(2.5)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
