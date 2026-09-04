import Foundation
import Combine
import AVFoundation

// Orchestrates a meeting note: mic + system tap -> two transcriber pipelines
// -> live segments -> file store -> summary on stop. Supports pause/resume
// and live auto-titling through the local agent.
@MainActor
final class MeetingRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var volatileMe = ""
    @Published private(set) var volatileThem = ""
    @Published private(set) var levels: [Float] = []
    @Published private(set) var currentNoteID: UUID?
    @Published private(set) var isSummarizing = false
    @Published private(set) var systemAudioUnavailable = false
    @Published private(set) var micLooksSilent = false

    var isActive: Bool { state == .recording || state == .starting || state == .paused }
    var isPaused: Bool { state == .paused }

    private let mic = MicCapture()
    private let tap = SystemAudioTap()
    private var mePipe: TranscriberPipeline?
    private var themPipe: TranscriberPipeline?
    private var ticker: Timer?
    private var resumedAt: Date?
    private var accumulated: TimeInterval = 0
    private var lastTitleAttempt: Date?
    private var titleTaskRunning = false

    unowned let store: NoteStore
    unowned let agent: AgentBridge

    init(store: NoteStore, agent: AgentBridge) {
        self.store = store
        self.agent = agent
    }

    // MARK: - Settings

    private var autoSummary: Bool { UserDefaults.standard.object(forKey: "autoSummary") as? Bool ?? true }
    private var autoTitle: Bool { UserDefaults.standard.object(forKey: "autoTitle") as? Bool ?? true }

    // MARK: - Lifecycle

    func start() async -> UUID? {
        await beginCapture(existingNoteID: nil)
    }

    // Reopens a stopped note and keeps appending to its transcript.
    func resumeNote(id: UUID) async -> UUID? {
        guard state == .idle || isFailed else { return currentNoteID }
        return await beginCapture(existingNoteID: id)
    }

    private func beginCapture(existingNoteID: UUID?) async -> UUID? {
        guard state == .idle || isFailed else { return currentNoteID }
        state = .starting
        volatileMe = ""
        volatileThem = ""
        levels = []
        lastTitleAttempt = nil

        guard await MicCapture.requestPermission() else {
            state = .failed("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.")
            return nil
        }

        let note: NoteMeta
        if let existingNoteID, let existing = store.meta(id: existingNoteID) {
            note = existing
            segments = store.loadSegments(noteID: existingNoteID)
            accumulated = existing.duration
            elapsed = existing.duration
        } else {
            // Create the note first so the user sees "Preparing" instead of nothing
            // while the on-device model downloads on first use.
            note = store.createNote()
            segments = []
            accumulated = 0
            elapsed = 0
        }
        currentNoteID = note.id

        DebugLog.reset()
        DebugLog.log("recorder.begin note=\(note.id) resume=\(existingNoteID != nil)")
        let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
        do {
            try await TranscriberPipeline.ensureAssets(locale: locale)
        } catch {
            state = .failed("Could not prepare the on-device speech model: \(error.localizedDescription)")
            if existingNoteID == nil {
                store.deleteNote(id: note.id)
            }
            currentNoteID = nil
            return nil
        }
        if existingNoteID != nil {
            commit(channel: "system", text: "Resumed")
        }

        let mePipe = TranscriberPipeline(label: "me")
        let themPipe = TranscriberPipeline(label: "them")
        self.mePipe = mePipe
        self.themPipe = themPipe

        mePipe.onResult = { [weak self] text, isFinal in
            self?.handleResult(channel: "me", text: text, isFinal: isFinal)
        }
        themPipe.onResult = { [weak self] text, isFinal in
            self?.handleResult(channel: "them", text: text, isFinal: isFinal)
        }

        do {
            try await mePipe.start(locale: locale)
            try await themPipe.start(locale: locale)
        } catch {
            state = .failed("Could not start transcription: \(error.localizedDescription)")
            return nil
        }

        mic.onBuffer = { [weak mePipe] buffer in mePipe?.feed(buffer) }
        mic.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.pushLevel(level) }
        }
        tap.onBuffer = { [weak themPipe] buffer in themPipe?.feed(buffer) }

        do {
            // Raw capture. Voice-processing AEC on macOS silences the input
            // when no output is rendering and fights the call app's own AEC.
            try mic.start(echoCancellation: false)
        } catch {
            state = .failed("Could not start the microphone: \(error.localizedDescription)")
            await teardownPipelines()
            return nil
        }

        do {
            try tap.start()
            systemAudioUnavailable = false
            DebugLog.log("system audio tap started")
        } catch {
            // Mic-only still works (in-person meetings); the note view shows a hint.
            systemAudioUnavailable = true
            DebugLog.log("system audio tap failed: \(error)")
        }

        resumedAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        state = .recording
        return note.id
    }

    func pause() {
        guard state == .recording else { return }
        if let resumedAt { accumulated += Date().timeIntervalSince(resumedAt) }
        resumedAt = nil
        mic.stop()
        tap.stop()
        flushVolatile()
        commit(channel: "system", text: "Paused")
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try mic.start(echoCancellation: false)
        } catch {
            state = .failed("Could not restart the microphone: \(error.localizedDescription)")
            return
        }
        if !systemAudioUnavailable {
            try? tap.start()
        }
        commit(channel: "system", text: "Resumed")
        resumedAt = Date()
        state = .recording
    }

    func stop() async {
        guard isActive else { return }
        let wasPaused = state == .paused
        state = .stopping
        ticker?.invalidate()
        ticker = nil
        if let resumedAt { accumulated += Date().timeIntervalSince(resumedAt) }
        resumedAt = nil
        elapsed = accumulated
        if !wasPaused {
            mic.stop()
            tap.stop()
        }
        await teardownPipelines()
        flushVolatile()

        if let id = currentNoteID, var meta = store.meta(id: id) {
            meta.duration = elapsed
            store.save(meta: meta)
            state = .idle
            currentNoteID = nil
            if autoSummary {
                await generateSummary(noteID: id)
            }
        } else {
            state = .idle
            currentNoteID = nil
        }
    }

    private func tick() {
        guard state == .recording else { return }
        if let resumedAt { elapsed = accumulated + Date().timeIntervalSince(resumedAt) }
        // Surface a dead microphone instead of recording silence for an hour.
        if elapsed > 8, levels.count >= 12 {
            let peak = levels.suffix(16).max() ?? 0
            micLooksSilent = peak < 0.0015 && segments.isEmpty && volatileMe.isEmpty
        } else {
            micLooksSilent = false
        }
        maybeAutoTitle()
    }

    private func flushVolatile() {
        if !volatileMe.isEmpty { commit(channel: "me", text: volatileMe) }
        if !volatileThem.isEmpty { commit(channel: "them", text: volatileThem) }
        volatileMe = ""
        volatileThem = ""
    }

    private func teardownPipelines() async {
        await mePipe?.finishAndWait()
        await themPipe?.finishAndWait()
        mePipe = nil
        themPipe = nil
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    func clearFailure() {
        if isFailed { state = .idle }
    }

    // MARK: - Results

    private func handleResult(channel: String, text: String, isFinal: Bool) {
        if isFinal {
            if channel == "me" { volatileMe = "" } else { volatileThem = "" }
            commit(channel: channel, text: text)
        } else {
            if channel == "me" { volatileMe = text } else { volatileThem = text }
        }
    }

    private func commit(channel: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let segment = TranscriptSegment(t: elapsed, channel: channel, text: trimmed)
        segments.append(segment)
        if let id = currentNoteID {
            store.appendSegment(noteID: id, segment)
        }
    }

    private func pushLevel(_ level: Float) {
        levels.append(level)
        if levels.count > 24 { levels.removeFirst(levels.count - 24) }
    }

    // MARK: - Live auto-title

    private func maybeAutoTitle() {
        guard autoTitle, !titleTaskRunning, let id = currentNoteID, let meta = store.meta(id: id) else { return }
        guard meta.titleLocked != true else { return }
        let spoken = segments.filter { $0.channel != "system" }
        guard spoken.count >= 6 else { return }
        // First attempt once there is real content, then refresh every 2 minutes.
        if let last = lastTitleAttempt, Date().timeIntervalSince(last) < 120 { return }
        guard !meta.isUntitled || spoken.count >= 6 else { return }
        lastTitleAttempt = Date()
        titleTaskRunning = true
        let prompt = AgentPrompts.title(segments: spoken)
        Task { [weak self] in
            guard let self else { return }
            defer { self.titleTaskRunning = false }
            guard let raw = try? await self.agent.run(prompt: prompt) else { return }
            let title = raw.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.")) ?? ""
            guard !title.isEmpty, title != "New note", title.count <= 80 else { return }
            if var meta = self.store.meta(id: id), meta.titleLocked != true {
                meta.title = title
                self.store.save(meta: meta)
            }
        }
    }

    // MARK: - Summary

    func generateSummary(noteID: UUID) async {
        let segments = store.loadSegments(noteID: noteID).filter { $0.channel != "system" }
        guard !segments.isEmpty else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let thoughts = store.loadThoughts(noteID: noteID)
        let captures = store.loadAttachments(noteID: noteID)
        let prompt = AgentPrompts.summary(segments: segments, thoughts: thoughts, captures: captures)
        guard let output = try? await agent.run(prompt: prompt) else { return }

        var summary = output
        if let range = output.range(of: "TITLE:") {
            let afterTitle = output[range.upperBound...]
            let titleLine = afterTitle.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
            if !titleLine.isEmpty, var meta = store.meta(id: noteID), meta.titleLocked != true {
                meta.title = titleLine
                store.save(meta: meta)
            }
            if let newlineIndex = afterTitle.firstIndex(where: { $0.isNewline }) {
                summary = String(afterTitle[afterTitle.index(after: newlineIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        store.saveSummary(noteID: noteID, summary)
    }
}
