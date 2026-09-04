import Foundation
import Combine
import AVFoundation

// Orchestrates a meeting note: mic + system tap -> two transcriber pipelines
// -> live segments -> file store -> summary on stop.
@MainActor
final class MeetingRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case recording
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

    var isActive: Bool { state == .recording || state == .starting }

    private let mic = MicCapture()
    private let tap = SystemAudioTap()
    private var mePipe: TranscriberPipeline?
    private var themPipe: TranscriberPipeline?
    private var ticker: Timer?
    private var startedAt: Date?

    unowned let store: NoteStore
    unowned let agent: AgentBridge

    init(store: NoteStore, agent: AgentBridge) {
        self.store = store
        self.agent = agent
    }

    // MARK: - Lifecycle

    func start() async -> UUID? {
        guard state == .idle || isFailed else { return currentNoteID }
        state = .starting
        segments = []
        volatileMe = ""
        volatileThem = ""
        elapsed = 0
        levels = []

        guard await MicCapture.requestPermission() else {
            state = .failed("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.")
            return nil
        }

        let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
        do {
            try await TranscriberPipeline.ensureAssets(locale: locale)
        } catch {
            state = .failed("Could not prepare the on-device speech model: \(error.localizedDescription)")
            return nil
        }

        let note = store.createNote()
        currentNoteID = note.id

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
            try mic.start(echoCancellation: true)
        } catch {
            state = .failed("Could not start the microphone: \(error.localizedDescription)")
            await teardownPipelines()
            return nil
        }

        do {
            try tap.start()
            systemAudioUnavailable = false
        } catch {
            // Mic-only still works (in-person meetings); the note view shows a hint.
            systemAudioUnavailable = true
        }

        startedAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        state = .recording
        return note.id
    }

    func stop() async {
        guard state == .recording || state == .starting else { return }
        state = .stopping
        ticker?.invalidate()
        ticker = nil
        mic.stop()
        tap.stop()
        await teardownPipelines()

        // Flush any remaining volatile text as final segments.
        if !volatileMe.isEmpty { commit(channel: "me", text: volatileMe) }
        if !volatileThem.isEmpty { commit(channel: "them", text: volatileThem) }
        volatileMe = ""
        volatileThem = ""

        if let id = currentNoteID, var meta = store.meta(id: id) {
            meta.duration = elapsed
            store.save(meta: meta)
            state = .idle
            await generateSummary(noteID: id)
        } else {
            state = .idle
        }
        currentNoteID = nil
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

    // MARK: - Summary

    func generateSummary(noteID: UUID) async {
        let segments = store.loadSegments(noteID: noteID)
        guard !segments.isEmpty else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let thoughts = store.loadThoughts(noteID: noteID)
        let prompt = AgentPrompts.summary(segments: segments, thoughts: thoughts)
        guard let output = try? await agent.run(prompt: prompt) else { return }

        var summary = output
        if let range = output.range(of: "TITLE:") {
            let afterTitle = output[range.upperBound...]
            let titleLine = afterTitle.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
            if !titleLine.isEmpty, var meta = store.meta(id: noteID) {
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
