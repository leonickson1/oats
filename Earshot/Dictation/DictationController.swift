import Foundation
import Combine
import AVFoundation

// Wispr-style dictation: hotkey toggles listening, speech is transcribed
// on-device, and the finalized text is typed into the frontmost app.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var levels: [Float] = []
    @Published private(set) var liveText = ""
    @Published private(set) var lastInsertedText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var history: [String] = []

    private let mic = MicCapture()
    private var pipe: TranscriberPipeline?
    private var finalizedText = ""

    var isActive: Bool { state == .listening || state == .starting }

    // MARK: - Controls

    func toggle() {
        switch state {
        case .idle: Task { await start() }
        case .listening: Task { await accept() }
        default: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        state = .starting
        lastError = nil
        finalizedText = ""
        liveText = ""
        levels = []

        guard await MicCapture.requestPermission() else {
            lastError = "Microphone access was denied."
            state = .idle
            return
        }

        let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
        do {
            try await TranscriberPipeline.ensureAssets(locale: locale)
        } catch {
            lastError = "Could not prepare the speech model: \(error.localizedDescription)"
            state = .idle
            return
        }

        let pipe = TranscriberPipeline(label: "dictation")
        self.pipe = pipe
        pipe.onResult = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                self.finalizedText += (self.finalizedText.isEmpty ? "" : " ") + text.trimmingCharacters(in: .whitespaces)
                self.liveText = self.finalizedText
            } else {
                self.liveText = self.finalizedText.isEmpty ? text : self.finalizedText + " " + text
            }
        }

        do {
            try await pipe.start(locale: locale)
        } catch {
            lastError = "Could not start transcription: \(error.localizedDescription)"
            state = .idle
            return
        }

        mic.onBuffer = { [weak pipe] buffer in pipe?.feed(buffer) }
        mic.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.pushLevel(level) }
        }

        do {
            // No echo cancellation for dictation: highest mic fidelity.
            try mic.start(echoCancellation: false)
            state = .listening
        } catch {
            lastError = "Could not start the microphone: \(error.localizedDescription)"
            await pipe.finishAndWait()
            self.pipe = nil
            state = .idle
        }
    }

    func accept() async {
        guard state == .listening else { return }
        state = .finishing
        mic.stop()
        await pipe?.finishAndWait()
        pipe = nil

        let text = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lastInsertedText = text
            history.insert(text, at: 0)
            if history.count > 20 { history.removeLast(history.count - 20) }
            let pasted = TextInserter.insert(text)
            if !pasted {
                lastError = "Text copied to the clipboard. Grant Accessibility access to insert it automatically."
            }
        }
        liveText = ""
        state = .idle
    }

    func cancel() async {
        guard isActive else { return }
        state = .finishing
        mic.stop()
        await pipe?.finishAndWait()
        pipe = nil
        liveText = ""
        finalizedText = ""
        state = .idle
    }

    private func pushLevel(_ level: Float) {
        levels.append(level)
        if levels.count > 24 { levels.removeFirst(levels.count - 24) }
    }
}
