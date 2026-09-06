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
    // Smoothed, character-by-character reveal of the volatile text so the live
    // transcript looks like it is being written continuously instead of popping
    // in whole clauses. The recognizer feeds volatile*, a fast timer catches
    // display* up to it.
    @Published private(set) var displayMe = ""
    @Published private(set) var displayThem = ""
    @Published private(set) var levels: [Float] = []
    @Published private(set) var currentNoteID: UUID?
    @Published private(set) var isSummarizing = false
    @Published private(set) var systemAudioUnavailable = false
    @Published private(set) var micLooksSilent = false
    // A short label shown app-wide while the local model is enriching notes in the
    // background (knowledge graph / action items). nil = nothing running.
    @Published private(set) var enrichmentLabel: String?
    private var enrichGraphCount = 0
    private var enrichActionsCount = 0

    var isActive: Bool { state == .recording || state == .starting || state == .paused }
    var isPaused: Bool { state == .paused }

    private let mic = MicCapture()
    private let tap = SystemAudioTap()
    private var audioRecorder: AudioFileRecorder?
    private var mePipe: TranscriberPipeline?
    private var themPipe: TranscriberPipeline?
    private var ticker: Timer?
    private var revealTimer: Timer?
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
        displayMe = ""
        displayThem = ""
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

        // Save the whole meeting to disk alongside the transcript so it can be
        // replayed line by line. Captured strongly by the audio callbacks; it is
        // torn down in stop().
        let audioRecorder = AudioFileRecorder(dir: store.dir(for: note.id))
        self.audioRecorder = audioRecorder

        mic.onBuffer = { [weak mePipe] buffer in
            mePipe?.feed(buffer)
            audioRecorder.appendMic(buffer)
        }
        mic.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.pushLevel(level) }
        }
        tap.onBuffer = { [weak themPipe] buffer in
            themPipe?.feed(buffer)
            audioRecorder.appendSystem(buffer)
        }

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
        startReveal()
        state = .recording
        return note.id
    }

    func pause() {
        guard state == .recording else { return }
        if let resumedAt { accumulated += Date().timeIntervalSince(resumedAt) }
        resumedAt = nil
        stopReveal()
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
        startReveal()
        state = .recording
    }

    func stop() async {
        guard isActive else { return }
        let wasPaused = state == .paused
        state = .stopping
        ticker?.invalidate()
        ticker = nil
        stopReveal()
        if let resumedAt { accumulated += Date().timeIntervalSince(resumedAt) }
        resumedAt = nil
        elapsed = accumulated
        if !wasPaused {
            mic.stop()
            tap.stop()
        }
        await teardownPipelines()
        flushVolatile()

        // Mix the raw mic + system streams down to audio.m4a off the main thread.
        if let audioRecorder {
            self.audioRecorder = nil
            await Task.detached(priority: .utility) { audioRecorder.finishAndMix() }.value
        }

        if let id = currentNoteID, var meta = store.meta(id: id) {
            meta.duration = elapsed
            store.save(meta: meta)   // save() bumps revision so the note view reloads and finds the audio
            state = .idle
            currentNoteID = nil
            // If the user chose a downloadable engine (Whisper or Parakeet), re-transcribe
            // the recording for higher accuracy before summarizing, so the summary reads
            // the better transcript.
            await maybePostTranscribe(noteID: id)
            if autoSummary {
                await generateSummary(noteID: id)
            }
        } else {
            state = .idle
            currentNoteID = nil
        }
    }

    // MARK: - Whisper (after-the-meeting re-transcription)

    private var selectedTranscriptionID: String {
        UserDefaults.standard.string(forKey: "transcriptionModelID") ?? "apple"
    }

    // Replaces the live Apple transcript with a higher-accuracy pass over the mixed
    // audio, but only when the user selected a downloadable engine (Whisper or
    // Parakeet) and it is installed. These engines have no speaker separation, so
    // lines are stored on a single "mixed" channel; pause markers are kept.
    private func maybePostTranscribe(noteID: UUID) async {
        let id = selectedTranscriptionID
        let model = TranscriptionCatalog.model(id: id)
        let audioURL = AudioFileRecorder.audioURL(in: store.dir(for: noteID))
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }

        let lines: [(t: TimeInterval, text: String)]
        do {
            switch model.engine {
            case .whisper:
                guard WhisperEngine.isDownloaded(id: id) else { return }
                enrichmentLabel = "Transcribing with \(model.name)"
                lines = try await WhisperEngine.transcribe(audioURL: audioURL, id: id)
            case .parakeet:
                guard ParakeetEngine.isDownloaded(id: id) else { return }
                enrichmentLabel = "Transcribing with \(model.name)"
                lines = try await ParakeetEngine.transcribe(audioURL: audioURL, durationHint: elapsed)
            case .apple:
                return
            }
        } catch {
            DebugLog.log("post-transcribe failed: \(error)")
            refreshEnrichmentLabel()
            return
        }

        defer { refreshEnrichmentLabel() }
        guard !lines.isEmpty else { return }
        let markers = store.loadSegments(noteID: noteID).filter { $0.channel == "system" }
        var replaced = lines.map { TranscriptSegment(t: $0.t, channel: "mixed", text: $0.text) }
        replaced.append(contentsOf: markers)
        replaced.sort { $0.t < $1.t }
        store.replaceSegments(noteID: noteID, replaced)
        segments = replaced
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
        displayMe = ""
        displayThem = ""
    }

    // MARK: - Typewriter reveal

    private func startReveal() {
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.revealTick() }
        }
    }

    private func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    private func revealTick() {
        advance(&displayMe, toward: volatileMe)
        advance(&displayThem, toward: volatileThem)
    }

    // Moves `display` a few characters closer to `target`. Reveals faster when it
    // has fallen far behind so it keeps up with speech, and snaps back to the
    // shared prefix when the recognizer revises its hypothesis.
    private func advance(_ display: inout String, toward target: String) {
        if display == target { return }
        let d = Array(display)
        let t = Array(target)
        var common = 0
        let limit = min(d.count, t.count)
        while common < limit && d[common] == t[common] { common += 1 }
        var count = common < d.count ? common : d.count
        if count < t.count {
            let backlog = t.count - count
            count = min(t.count, count + max(2, backlog / 6))
        }
        let next = String(t[0..<min(count, t.count)])
        if next != display { display = next }
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
            if channel == "me" { volatileMe = ""; displayMe = "" } else { volatileThem = ""; displayThem = "" }
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
        let prompt = AgentPrompts.summary(segments: segments, thoughts: thoughts, captures: captures, assetsDir: store.assetsDir(for: noteID))
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
        // Action items and the knowledge graph fill in afterwards so the summary
        // shows immediately; each write bumps the store so the UI updates live.
        Task { [weak self] in
            await self?.extractActions(noteID: noteID)
            await self?.extractGraph(noteID: noteID)
        }
    }

    // Pull concrete to-dos out of a meeting and save them for the action hub.
    func extractActions(noteID: UUID) async {
        let summary = store.loadSummary(noteID: noteID)
        let segments = store.loadSegments(noteID: noteID).filter { $0.channel != "system" }
        guard !summary.isEmpty || !segments.isEmpty else { return }
        enrichActionsCount += 1; refreshEnrichmentLabel()
        defer { enrichActionsCount -= 1; refreshEnrichmentLabel() }
        let prompt = AgentPrompts.actionItems(summary: summary, segments: segments)
        guard let output = try? await agent.run(prompt: prompt) else { return }
        store.saveActions(noteID: noteID, ActionParsing.parse(output))
    }

    // Pull people/projects/topics out of a meeting for the knowledge graph.
    func extractGraph(noteID: UUID) async {
        let summary = store.loadSummary(noteID: noteID)
        let segments = store.loadSegments(noteID: noteID).filter { $0.channel != "system" }
        guard !summary.isEmpty || !segments.isEmpty else { return }
        enrichGraphCount += 1; refreshEnrichmentLabel()
        defer { enrichGraphCount -= 1; refreshEnrichmentLabel() }
        let prompt = AgentPrompts.entities(summary: summary, segments: segments)
        guard let output = try? await agent.run(prompt: prompt) else { return }
        store.saveGraph(noteID: noteID, GraphParsing.parse(output))
    }

    private func refreshEnrichmentLabel() {
        if enrichGraphCount > 0 && enrichActionsCount > 0 {
            enrichmentLabel = "Updating notes"
        } else if enrichGraphCount > 0 {
            enrichmentLabel = "Updating knowledge graph"
        } else if enrichActionsCount > 0 {
            enrichmentLabel = "Updating action items"
        } else {
            enrichmentLabel = nil
        }
    }
}
