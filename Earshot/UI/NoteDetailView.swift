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
            picker
            Divider()

            Group {
                switch tab {
                case .thoughts: thoughtsTab
                case .transcript: TranscriptPane(
                    segments: displayedSegments,
                    isLive: isLiveNote,
                    volatileMe: isLiveNote ? recorder.volatileMe : "",
                    volatileThem: isLiveNote ? recorder.volatileThem : "",
                    elapsed: isLiveNote ? recorder.elapsed : (store.meta(id: noteID)?.duration ?? 0),
                    systemAudioUnavailable: recorder.systemAudioUnavailable
                )
                case .summary: summaryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !chat.isEmpty { chatSection }
            bottomBar
        }
        .background(Theme.windowBG)
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
        VStack(alignment: .leading, spacing: 3) {
            TextField("New note", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
            HStack(spacing: 8) {
                if let meta = store.meta(id: noteID) {
                    Text(meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if isLiveNote {
                    if recorder.state == .starting {
                        Text("Preparing the on-device speech model")
                    } else {
                        Text(recorder.isPaused ? "Paused" : "Listening")
                            .foregroundStyle(recorder.isPaused ? Color.secondary : Theme.record)
                    }
                } else if recorder.isSummarizing {
                    Text("Summarizing with \(agent.activeAgentName)")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(NoteTab.allCases, id: \.self) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 380)
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    // MARK: - Thoughts (rich editor + attachments)

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
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            TextEditor(text: $thoughts, selection: $selection)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14)
                .overlay(alignment: .topLeading) {
                    if thoughts.characters.isEmpty {
                        Text("Type anything. Earshot keeps listening and takes the notes for you.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 19)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            if !attachments.isEmpty {
                AttachmentStrip(noteID: noteID, attachments: $attachments)
                    .padding(.horizontal, 18)
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
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                } else if summary.isEmpty {
                    VStack(spacing: 10) {
                        Text(isLiveNote ? "The summary is written when you stop." : "No summary yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        if !isLiveNote && !displayedSegments.isEmpty {
                            Button("Generate summary") {
                                Task { await recorder.generateSummary(noteID: noteID) }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(markdownish(summary))
                        .font(.system(size: 13.5))
                        .textSelection(.enabled)
                        .lineSpacing(3)
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
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
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
                .padding(12)
            }
            .frame(height: 160)
            .card()
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            .onChange(of: chat.count) {
                if let last = chat.last { withAnimation { proxy.scrollTo(last.id) } }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 7) {
            Text("Always get consent when transcribing others.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if isLiveNote {
                        Button {
                            if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                        } label: {
                            Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .help(recorder.isPaused ? "Resume" : "Pause")

                        Button {
                            app.stopMeetingNote()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.record)
                        .help("Stop and summarize")
                    }

                    HStack(spacing: 8) {
                        TextField("Ask anything about this meeting", text: $askText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .onSubmit { ask(askText) }
                        if isLiveNote {
                            Button("What did I miss?") { ask("What did I miss?") }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .disabled(isAsking)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .glassEffect(.regular, in: .capsule)
                }
            }
        }
        .padding(.horizontal, 18)
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

// MARK: - Transcript pane

struct TranscriptPane: View {
    let segments: [TranscriptSegment]
    let isLive: Bool
    let volatileMe: String
    let volatileThem: String
    let elapsed: TimeInterval
    let systemAudioUnavailable: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    statusRow
                    if segments.isEmpty && volatileMe.isEmpty && volatileThem.isEmpty {
                        Text(isLive ? "Listening" : "No transcript was captured.")
                            .font(.system(size: 13))
                            .italic(isLive)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else {
                        ForEach(segments) { segment in
                            if segment.channel == "system" {
                                systemMarker(segment)
                            } else {
                                row(who: segment.channel == "me" ? "Me" : "Them", text: segment.text, dim: false, t: segment.t)
                            }
                        }
                        if isLive && !volatileThem.isEmpty { row(who: "Them", text: volatileThem, dim: true, t: nil) }
                        if isLive && !volatileMe.isEmpty { row(who: "Me", text: volatileMe, dim: true, t: nil) }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
            .onChange(of: segments.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(elapsed.clockString)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Spacer()
            if isLive {
                Text(systemAudioUnavailable
                     ? "System audio is off; only your mic is heard. Allow System Audio Recording in Privacy & Security."
                     : "On-device transcription. Nothing leaves this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button {
                let text = segments.filter { $0.channel != "system" }
                    .map { "[\($0.t.clockString)] \($0.channel == "me" ? "Me" : "Them"): \($0.text)" }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy transcript")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card(radius: 10)
    }

    private func row(who: String, text: String, dim: Bool, t: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(who)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(who == "Me" ? Color.secondary : Theme.record)
                if let t {
                    Text(t.clockString)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.quaternary)
                }
            }
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(dim ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func systemMarker(_ segment: TranscriptSegment) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            Label(segment.text, systemImage: segment.text == "Paused" ? "pause" : "play")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}
