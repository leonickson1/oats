import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

// Local Parakeet transcription via FluidAudio (NVIDIA Parakeet TDT, CoreML on the
// Neural Engine). Models auto-download once from Hugging Face and then run fully
// on this Mac. Used for high-accuracy transcription AFTER a meeting, from the
// mixed audio.m4a; Apple's SpeechAnalyzer stays the live default. We use only
// FluidAudio's ASR here; its speaker diarization is a separate, later feature.
enum ParakeetEngine {
    enum Err: LocalizedError {
        case notAvailable
        var errorDescription: String? {
            switch self {
            case .notAvailable: return "This build was compiled without the Parakeet engine."
            }
        }
    }

    // FluidAudio caches its own models; we track completion with a simple flag so
    // the UI can show the model as ready without probing the HF cache layout.
    private static let downloadedKey = "parakeetDownloaded"

    static func isDownloaded(id: String) -> Bool {
        UserDefaults.standard.bool(forKey: downloadedKey)
    }

    // Downloads and warms the Parakeet models. No fractional progress is exposed,
    // so callers show an indeterminate spinner.
    static func download() async throws {
        #if canImport(FluidAudio)
        _ = try await AsrModels.downloadAndLoad(version: .v3)
        UserDefaults.standard.set(true, forKey: downloadedKey)
        #else
        throw Err.notAvailable
        #endif
    }

    // Transcribes an audio file. Parakeet returns one transcript with no speaker
    // separation; we split it into sentence-sized lines and spread timestamps across
    // the known duration so playback seeking still roughly lines up.
    static func transcribe(audioURL: URL, durationHint: TimeInterval) async throws -> [(t: TimeInterval, text: String)] {
        #if canImport(FluidAudio)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        UserDefaults.standard.set(true, forKey: downloadedKey)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return splitIntoLines(text, duration: durationHint)
        #else
        throw Err.notAvailable
        #endif
    }

    private static func splitIntoLines(_ text: String, duration: TimeInterval) -> [(t: TimeInterval, text: String)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        for ch in trimmed {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.isEmpty { sentences = [trimmed] }

        let total = max(1, sentences.reduce(0) { $0 + $1.count })
        let dur = max(0, duration)
        var acc = 0
        return sentences.map { s in
            let t = dur * Double(acc) / Double(total)
            acc += s.count
            return (t, s)
        }
    }
}
