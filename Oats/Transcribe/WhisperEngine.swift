import Foundation
#if canImport(WhisperKit)
import WhisperKit
#endif

// Local Whisper transcription via WhisperKit (CoreML on the Neural Engine).
// A model downloads once into Application Support/Oats/whisper and then runs
// fully on this Mac, nothing in the cloud. Whisper is used for high-accuracy
// transcription AFTER a meeting, from the mixed audio.m4a; Apple's SpeechAnalyzer
// stays the live default during the meeting.
enum WhisperEngine {
    enum Err: LocalizedError {
        case unknownModel
        case notAvailable
        var errorDescription: String? {
            switch self {
            case .unknownModel: return "Unknown transcription model."
            case .notAvailable: return "This build was compiled without the Whisper engine."
            }
        }
    }

    // The Hugging Face repo the CoreML models are published to.
    private static let repo = "argmaxinc/whisperkit-coreml"

    // Our catalog id -> WhisperKit model variant (a folder name inside the repo).
    static func variant(for id: String) -> String? {
        switch id {
        case "whisper-tiny": return "openai_whisper-tiny"
        case "whisper-small": return "openai_whisper-small"
        case "whisper-large-v3": return "openai_whisper-large-v3"
        case "whisper-large-v3-turbo": return "openai_whisper-large-v3-v20240930_turbo_632MB"
        default: return nil
        }
    }

    // Where we keep downloaded models, so we fully control checking + storage.
    static var baseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Oats/whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // WhisperKit's Hub lays a variant down at <base>/models/<repo>/<variant>.
    static func modelFolder(variant: String) -> URL {
        baseDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    // A finished model has its compiled CoreML packages (*.mlmodelc) on disk.
    static func isDownloaded(id: String) -> Bool {
        guard let v = variant(for: id) else { return false }
        let folder = modelFolder(variant: v)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    // Downloads a model, reporting 0...1 progress. Safe to call again; WhisperKit
    // skips files already present.
    static func download(id: String, progress: @escaping (Double) -> Void) async throws {
        guard let v = variant(for: id) else { throw Err.unknownModel }
        #if canImport(WhisperKit)
        _ = try await WhisperKit.download(
            variant: v,
            downloadBase: baseDir,
            from: repo
        ) { p in
            progress(p.fractionCompleted)
        }
        #else
        throw Err.notAvailable
        #endif
    }

    // Transcribes an audio file into timestamped lines. Whisper works on the mixed
    // mono file, so there is no speaker separation; every line is one transcript.
    static func transcribe(audioURL: URL, id: String) async throws -> [(t: TimeInterval, text: String)] {
        guard let v = variant(for: id) else { throw Err.unknownModel }
        #if canImport(WhisperKit)
        let config = WhisperKitConfig(
            model: v,
            downloadBase: baseDir,
            modelFolder: modelFolder(variant: v).path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        let results = try await whisper.transcribe(audioPath: audioURL.path)
        var out: [(TimeInterval, String)] = []
        for result in results {
            for seg in result.segments {
                let text = cleaned(seg.text)
                guard !text.isEmpty else { continue }
                out.append((TimeInterval(seg.start), text))
            }
        }
        return out
        #else
        throw Err.notAvailable
        #endif
    }

    // Whisper decorates lines with control tags and non-speech cues we don't want
    // in the transcript, e.g. "<|0.00|>", "[BLANK_AUDIO]", "(music)".
    private static func cleaned(_ raw: String) -> String {
        var s = raw
        while let open = s.firstIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s.removeSubrange(open...close)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower == "[blank_audio]" || lower == "(music)" || lower == "[music]" { return "" }
        return s
    }
}
