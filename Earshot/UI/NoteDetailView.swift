import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RichTextKit

enum NoteTab: String, CaseIterable {
    case thoughts = "My thoughts"
    case transcript = "Transcript"
    case summary = "Summary"
}

// A fresh capture whose read-off text is ready to paste below the image.
private struct CaptureTextOffer {
    let attachment: Attachment
    let text: String
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
    @State private var thoughtsAttr = NSAttributedString()
    @StateObject private var rich = RichTextContext()
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
    @State private var textOffer: CaptureTextOffer?
    @StateObject private var player = AudioPlaybackController()

    private var isLiveNote: Bool { recorder.isActive && recorder.currentNoteID == noteID }
    private var displayedSegments: [TranscriptSegment] { isLiveNote ? recorder.segments : savedSegments }

    // The saved recording, once a note is finished. Nil while still recording.
    private var audioURL: URL? {
        guard !isLiveNote, store.hasAudio(noteID: noteID) else { return nil }
        return store.audioURL(noteID: noteID)
    }

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
                    volatileMe: isLiveNote ? recorder.displayMe : "",
                    volatileThem: isLiveNote ? recorder.displayThem : "",
                    elapsed: isLiveNote ? recorder.elapsed : (store.meta(id: noteID)?.duration ?? 0),
                    audioURL: audioURL,
                    player: player,
                    systemAudioUnavailable: recorder.systemAudioUnavailable,
                    micLooksSilent: recorder.micLooksSilent,
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
        .onDisappear { player.teardown() }
        .onChange(of: store.revision) { reload() }
        .onChange(of: title) {
            guard loaded, var meta = store.meta(id: noteID), meta.title != title, !title.isEmpty else { return }
            meta.title = title
            meta.titleLocked = true
            store.save(meta: meta)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    // Captures always land inline in the notes. From another tab
                    // the note may not have a cursor yet, so this appends at the end.
                    let atEnd = tab != .thoughts
                    tab = .thoughts
                    Task {
                        if let att = await capture.captureRegion(noteID: noteID, at: isLiveNote ? recorder.elapsed : 0, inline: true) {
                            insertInline(capture.imageURL(noteID: noteID, att), atEnd: atEnd)
                            offerCaptureText(filename: att.value)
                        }
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
                            .map { seg -> String in
                                let who = seg.channel == "me" ? "Me: " : seg.channel == "them" ? "Them: " : ""
                                return "[\(seg.t.clockString)] \(who)\(seg.text)"
                            }
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Divider()
                    Menu("Export") {
                        Button("Copy as Markdown") {
                            ExportService.copyMarkdown(noteID: noteID, store: store)
                        }
                        Button("Save as Markdown…") {
                            ExportService.saveMarkdown(noteID: noteID, store: store)
                        }
                        Button("Export PDF…") {
                            ExportService.savePDF(noteID: noteID, store: store)
                        }
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
                let dest = capture.addImage(noteID: noteID, from: url, at: isLiveNote ? recorder.elapsed : 0, inline: true)
                if scoped { url.stopAccessingSecurityScopedResource() }
                insertInline(dest)
                if let dest { offerCaptureText(filename: dest.lastPathComponent) }
                attachments = store.loadAttachments(noteID: noteID)
            }
        }
    }

    // MARK: - Loading / saving

    private func load() {
        guard !loaded else { return }
        let meta = store.meta(id: noteID)
        title = meta?.title ?? "New note"
        thoughtsAttr = NotesRich.normalized(store.loadThoughtsAttributed(noteID: noteID))
        chat = store.loadChat(noteID: noteID)
        attachments = store.loadAttachments(noteID: noteID)
        savedSegments = store.loadSegments(noteID: noteID)
        if isLiveNote { tab = .transcript }
        else if meta?.hasSummary == true { tab = .summary }
        if let audioURL { player.load(audioURL) }
        loaded = true
    }

    private func reload() {
        guard loaded else { return }
        if !isLiveNote { savedSegments = store.loadSegments(noteID: noteID) }
        attachments = store.loadAttachments(noteID: noteID)
        if let meta = store.meta(id: noteID), meta.title != title { title = meta.title }
        // A finished recording writes audio.m4a; a resume rewrites it. load() no-ops
        // unless the file actually changed.
        if let audioURL { player.load(audioURL) } else { player.teardown() }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveDebounce?.cancel()
        let snapshot = thoughtsAttr
        saveDebounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.saveThoughtsAttributed(noteID: noteID, snapshot)
        }
    }

    // Applies one edit to both copies of the document: the mirror the view holds
    // (thoughtsAttr, which is what gets saved) and the live editor, through
    // RichTextKit's action pipeline. Typing keeps them converged afterwards.
    private func applyEdit(_ piece: NSAttributedString, at range: NSRange) {
        let mirror = NSMutableAttributedString(attributedString: thoughtsAttr)
        let location = min(range.location, mirror.length)
        let safe = NSRange(location: location, length: min(range.length, mirror.length - location))
        mirror.replaceCharacters(in: safe, with: piece)
        thoughtsAttr = mirror
        rich.trigger(.replaceText(in: safe, with: piece))
        rich.trigger(.selectRange(NSRange(location: safe.location + piece.length, length: 0)))
        scheduleSave()
    }

    // Places a just-added image in the notes editor at the cursor, on its own line.
    // atEnd appends instead, for captures taken while another tab was open.
    private func insertInline(_ url: URL?, atEnd: Bool = false) {
        guard let url else { return }
        let range = atEnd ? NSRange(location: thoughtsAttr.length, length: 0) : rich.selectedRange
        applyEdit(NotesRich.imagePiece(url: url), at: range)
    }

    // Once the on-device OCR of a fresh capture lands, offer its text with one
    // click, right in the editor. No expanding, no extra steps.
    private func offerCaptureText(filename: String) {
        Task {
            var found: Attachment?
            for _ in 0..<20 {
                found = store.loadAttachments(noteID: noteID).first(where: { $0.value == filename })
                if found?.ocrText != nil { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            attachments = store.loadAttachments(noteID: noteID)
            guard let found, let text = found.ocrText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                textOffer = CaptureTextOffer(attachment: found, text: text)
            }
        }
    }

    // Selecting an inline image surfaces the paste-its-text offer for it; moving
    // the selection anywhere else puts the bar away.
    private func updateOfferForSelection() {
        guard tab == .thoughts else { return }
        let selection = rich.selectedRange
        if selection.length > 0,
           let filename = thoughtsAttr.captureFilename(in: selection),
           let found = attachments.first(where: { $0.value == filename }),
           let text = found.ocrText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if textOffer?.attachment.id != found.id {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    textOffer = CaptureTextOffer(attachment: found, text: text)
                }
            }
        } else if selection.length > 0, textOffer != nil {
            withAnimation { textOffer = nil }
        }
    }

    // Places the text read from a capture under that image in the notes. Only the
    // text is ever inserted, never another copy of the image: if the image cannot
    // be located in the document, the text goes at the end on its own.
    private func insertCaptureText(_ attachment: Attachment, _ text: String) {
        let piece = NotesRich.textPiece(text)
        if let imageRange = thoughtsAttr.rangeOfAttachment(filename: attachment.value) {
            applyEdit(piece, at: NSRange(location: imageRange.location + imageRange.length, length: 0))
        } else {
            applyEdit(piece, at: NSRange(location: thoughtsAttr.length, length: 0))
        }
    }

    // Removes a capture everywhere: its card in the strip, its file on disk, and
    // its inline copy in the notes text, if it has one.
    private func deleteCapture(_ attachment: Attachment) {
        if attachment.kind == "image", let imageRange = thoughtsAttr.rangeOfAttachment(filename: attachment.value) {
            // Take the following newline with it so no blank line is left behind.
            var range = imageRange
            let after = imageRange.location + imageRange.length
            if after < thoughtsAttr.length, thoughtsAttr.attributedSubstring(from: NSRange(location: after, length: 1)).string == "\n" {
                range.length += 1
            }
            applyEdit(NSAttributedString(string: ""), at: range)
        }
        capture.deleteAttachment(noteID: noteID, attachment)
        attachments = store.loadAttachments(noteID: noteID)
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
            RichTextToolbar(context: rich) {
                showLinkPrompt = true
            } onAttachImage: {
                showImagePicker = true
            } onCapture: {
                Task {
                    let att = await capture.captureRegion(noteID: noteID, at: isLiveNote ? recorder.elapsed : 0, inline: true)
                    if let att {
                        insertInline(capture.imageURL(noteID: noteID, att))
                        offerCaptureText(filename: att.value)
                    }
                    attachments = store.loadAttachments(noteID: noteID)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            RichTextEditor(text: $thoughtsAttr, context: rich, format: .archivedData) { component in
                if let textView = component as? NSTextView {
                    textView.drawsBackground = false
                    textView.allowsUndo = true
                    textView.textContainerInset = NSSize(width: 16, height: 12)
                    textView.isAutomaticQuoteSubstitutionEnabled = false
                    textView.isAutomaticDashSubstitutionEnabled = false
                }
                if let richView = component as? RichTextView {
                    richView.imageConfiguration = RichTextImageConfiguration(
                        pasteConfiguration: .enabled,
                        dropConfiguration: .enabled,
                        maxImageSize: (width: .points(440), height: .frame)
                    )
                }
            }
            .richTextEditorStyle(.init(font: NotesRich.font, fontColor: .labelColor, backgroundColor: .clear))
            .id(noteID)
            .onChange(of: thoughtsAttr) { scheduleSave() }
            .onReceive(rich.objectWillChange) { _ in
                DispatchQueue.main.async { updateOfferForSelection() }
            }
            .overlay(alignment: .bottom) {
                if let offer = textOffer {
                    HStack(spacing: 10) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Text found in this screenshot.")
                            .font(.system(size: 12.5))
                        Button("Paste it below the image") {
                            insertCaptureText(offer.attachment, offer.text)
                            withAnimation { textOffer = nil }
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        Button {
                            withAnimation { textOffer = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                if thoughtsAttr.length == 0 {
                    Text("Write notes, screenshot, or drop in an image. It lands right where your cursor is.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 21)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }

            // Images live inline in the editor, never in a bottom strip. Only links
            // keep a card row down here.
            if attachments.contains(where: { $0.kind == "link" }) {
                AttachmentStrip(
                    noteID: noteID,
                    attachments: $attachments,
                    onDelete: { attachment in deleteCapture(attachment) }
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(url.pathExtension.lowercased()) {
                let dest = capture.addImage(noteID: noteID, from: url, at: isLiveNote ? recorder.elapsed : 0, inline: true)
                insertInline(dest)
                if let dest { offerCaptureText(filename: dest.lastPathComponent) }
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
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.top, 70)
                    .frame(maxWidth: .infinity)
                } else {
                    MarkdownView(text: summary)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        if !isLiveNote {
                            Button("Regenerate") {
                                Task { await recorder.generateSummary(noteID: noteID) }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                        }
                        CopyButton(text: summary)
                    }
                    .padding(.top, 4)
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Chat")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if agent.activeAgentName == "no agent" {
                    SettingsLink {
                        Label("Connect an AI", systemImage: "link")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Text("via \(agent.activeAgentName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    clearChat()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close chat")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            chatScroll
        }
        .card(radius: 16)
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .frame(maxWidth: 728)
        .frame(maxWidth: .infinity)
    }

    private var chatScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chat.enumerated()), id: \.element.id) { index, message in
                        if message.role == "user" {
                            if index > 0 {
                                Divider().opacity(0.35).padding(.vertical, 12)
                            }
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 3)
                                Text(message.text)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.bottom, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                MarkdownView(text: message.text)
                                    .textSelection(.enabled)
                                if !message.text.isEmpty {
                                    CopyButton(text: message.text)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 0).id(message.id)
                    }
                    if isAsking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking \(agent.activeAgentName)")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            .onChange(of: chat.count) {
                if let last = chat.last { withAnimation { proxy.scrollTo(last.id) } }
            }
        }
    }

    private func clearChat() {
        chat = []
        store.clearChat(noteID: noteID)
    }

    // MARK: - Floating bottom bar

    // Measured so the bar can compress in the docked companion window; below
    // this width the ask field would otherwise be squeezed out entirely.
    @State private var barWidth: CGFloat = 728
    private var barIsNarrow: Bool { barWidth < 600 }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !displayedSegments.isEmpty && !isAsking {
                recipeChips
            }
            GlassEffectContainer(spacing: 9) {
                HStack(alignment: .center, spacing: 9) {
                    // At companion width the transport buttons go icon-only so
                    // the ask field keeps room to breathe.
                    if isLiveNote {
                        if recorder.isPaused {
                            barButton(icon: "record.circle", label: barIsNarrow ? nil : "Resume", help: "Resume recording") {
                                recorder.resume()
                            }
                        } else {
                            barButton(icon: "pause.fill", label: nil, help: "Pause") {
                                recorder.pause()
                            }
                            barButton(icon: "stop.fill", label: barIsNarrow ? nil : "Stop", help: "Stop and summarize") {
                                app.stopMeetingNote()
                            }
                        }
                    } else if !recorder.isActive && !displayedSegments.isEmpty {
                        // A finished note can keep recording again onto the same transcript.
                        barButton(icon: "record.circle", label: barIsNarrow ? nil : "Resume", help: "Record more into this note") {
                            app.resumeMeetingNote(id: noteID)
                        }
                    }

                    HStack(alignment: .center, spacing: 10) {
                        TextField("Ask anything", text: $askText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .onSubmit { ask(askText) }
                            .frame(minWidth: 70)
                            .layoutPriority(1)
                        if isAsking {
                            ProgressView().controlSize(.small)
                        } else if isLiveNote {
                            if barIsNarrow {
                                Button {
                                    ask("What did I miss?")
                                } label: {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(7)
                                        .background(.quaternary.opacity(0.6), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .help("What did I miss?")
                            } else {
                                Button {
                                    ask("What did I miss?")
                                } label: {
                                    Text("What did I miss?")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 7)
                                        .background(.quaternary.opacity(0.6), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ModelPickerMenu(agent: agent, compact: barIsNarrow)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .frame(maxWidth: 728)

            Text("Always get consent when transcribing others.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            barWidth = width
        }
    }

    private func barButton(icon: String, label: String?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.record)
                if let label {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, label == nil ? 0 : 19)
            .frame(width: label == nil ? 48 : nil, height: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(help)
    }

    // Canned questions, Granola-recipe style. Real prompts, no dead chrome.
    private var recipeChips: some View {
        HStack(spacing: 8) {
            recipeChip("Write follow-up email", icon: "envelope") {
                ask("Draft a short follow-up email for this meeting: one line of context, a few bullet recap, then action items with owners. Plain text, ready to paste.")
            }
            recipeChip("List action items", icon: "checklist") {
                ask("List every action item from this meeting as \"- [owner] task\". If there are none, say so plainly.")
            }
            recipeChip("Write TLDR", icon: "text.alignleft") {
                ask("Write a three sentence TLDR of this meeting.")
            }
        }
        .frame(maxWidth: 728, alignment: .leading)
    }

    private func recipeChip(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(isAsking)
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
                    thoughts: thoughtsAttr.string,
                    summary: store.loadSummary(noteID: noteID)
                )
            }
            // Show a placeholder assistant bubble that fills in as text streams.
            let placeholder = ChatMessage(role: "assistant", text: "")
            chat.append(placeholder)
            var streamed = ""
            do {
                let answer = try await agent.runStreaming(prompt: prompt) { delta in
                    streamed += delta
                    if let idx = chat.firstIndex(where: { $0.id == placeholder.id }) {
                        chat[idx] = ChatMessage(role: "assistant", text: streamed, id: placeholder.id)
                    }
                }
                if let idx = chat.firstIndex(where: { $0.id == placeholder.id }) {
                    chat[idx] = ChatMessage(role: "assistant", text: answer, id: placeholder.id)
                }
                store.appendChat(noteID: noteID, ChatMessage(role: "assistant", text: answer, id: placeholder.id))
            } catch {
                if let idx = chat.firstIndex(where: { $0.id == placeholder.id }) {
                    chat[idx] = ChatMessage(role: "assistant", text: error.localizedDescription, id: placeholder.id)
                }
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
    let audioURL: URL?
    @ObservedObject var player: AudioPlaybackController
    let systemAudioUnavailable: Bool
    let micLooksSilent: Bool
    let canGenerateSummary: Bool
    let onGenerateSummary: () -> Void

    // A finished note has a saved recording, so lines can be tapped to play.
    private var seekable: Bool { audioURL != nil }

    var body: some View {
        VStack(spacing: 0) {
            if seekable {
                AudioPlayerBar(player: player)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !seekable { sessionCard }
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
                                    .buttonBorderShape(.capsule)
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
                    .padding(.top, seekable ? 6 : 12)
                    .padding(.bottom, 10)
                }
                .onChange(of: segments.count) {
                    withAnimation { proxy.scrollTo("bottom") }
                }
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
                    Text(statusLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(micLooksSilent ? Color.orange : Color.secondary)
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

    // The line the play head is currently inside, so it can be highlighted.
    private var activeSegmentID: UUID? {
        guard seekable, player.isLoaded, player.isPlaying || player.currentTime > 0.05 else { return nil }
        let t = player.currentTime
        var result: UUID?
        for seg in segments where seg.channel != "system" {
            if seg.t <= t + 0.3 { result = seg.id } else { break }
        }
        return result
    }

    private var bubbles: some View {
        let active = activeSegmentID
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if segment.channel == "system" {
                    DashedMarker(label: segment.text, icon: segment.text == "Paused" ? "pause" : "play")
                } else {
                    if speakerChanged(at: index) {
                        HStack(spacing: 7) {
                            Text(speakerLabel(segment.channel))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(segment.channel == "them" ? Theme.record : Color.secondary)
                            if seekable {
                                Text(segment.t.clockString)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, index == 0 ? 0 : 8)
                        .padding(.leading, 2)
                    }
                    segmentBubble(segment, isActive: segment.id == active)
                }
            }
            if isLive && !volatileThem.isEmpty {
                bubble(volatileThem, dim: true, active: false, selectable: false)
            }
            if isLive && !volatileMe.isEmpty {
                bubble(volatileMe, dim: true, active: false, selectable: false)
            }
        }
    }

    @ViewBuilder
    private func segmentBubble(_ segment: TranscriptSegment, isActive: Bool) -> some View {
        if seekable {
            Button {
                player.playFrom(segment.t)
            } label: {
                bubble(segment.text, dim: false, active: isActive, selectable: false)
            }
            .buttonStyle(.plain)
            .help("Play from \(segment.t.clockString)")
        } else {
            bubble(segment.text, dim: false, active: isActive, selectable: true)
        }
    }

    // "mixed" is Whisper's single-channel output (no speaker separation).
    private func speakerLabel(_ channel: String) -> String {
        switch channel {
        case "me": return "Me"
        case "them": return "Them"
        default: return "Transcript"
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

    private var statusLine: String {
        if micLooksSilent {
            return "The microphone looks silent. Check the input device, its volume, or whether another app holds it."
        }
        if systemAudioUnavailable {
            return "System audio is off; only your mic is heard. Allow System Audio Recording in Privacy & Security."
        }
        return "Transcribing on this Mac. Nothing leaves your device."
    }

    @ViewBuilder
    private func bubble(_ text: String, dim: Bool, active: Bool, selectable: Bool) -> some View {
        let content = Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(dim ? Color.secondary : Color.primary)
            .lineSpacing(2.5)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                if active { shape.fill(Theme.record.opacity(0.16)) }
                else { shape.fill(.quaternary.opacity(0.45)) }
            }
            .overlay(alignment: .leading) {
                if active {
                    Capsule().fill(Theme.record).frame(width: 3).padding(.vertical, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        if selectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

// A compact transport for the saved recording: play/pause, a scrubber, and the
// running time. Tapping a transcript line seeks this player straight to that line.
struct AudioPlayerBar: View {
    @ObservedObject var player: AudioPlaybackController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.record)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help(player.isPlaying ? "Pause" : "Play the recording")

            Text(player.currentTime.clockString)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.currentTime = $0 }),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    if editing { player.beginScrub() }
                    else { player.endScrub(to: player.currentTime) }
                }
            )
            .controlSize(.small)
            .tint(Theme.record)

            Text(player.duration.clockString)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }
}
