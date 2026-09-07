import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple's on-device model (macOS 26 Apple Intelligence), reached through the
// FoundationModels framework. Zero download, fully local, no API key. Available
// only on supported hardware with Apple Intelligence turned on; we detect that
// and degrade gracefully everywhere else.
enum AppleModel {
    enum Status: Equatable {
        case available
        case unavailable(String)   // human-readable reason
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(describe(reason))
            @unknown default:
                return .unavailable("Not available")
            }
        } else {
            return .unavailable("Requires macOS 26")
        }
        #else
        return .unavailable("Not supported in this build")
        #endif
    }

    static var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    static var reason: String? {
        if case .unavailable(let why) = status { return why }
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings"
        case .modelNotReady: return "The model is still downloading, try again shortly"
        @unknown default: return "Not available"
        }
    }
    #endif

    enum ModelError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let why): return why }
        }
    }

    static func run(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else { throw ModelError.unavailable(reason ?? "Apple Intelligence is not available.") }
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw ModelError.unavailable("Apple Intelligence is not available on this Mac.")
    }

    // Streams the answer as it is generated. FoundationModels hands back cumulative
    // snapshots (the whole answer so far each time), so we diff against what we have
    // already emitted and forward only the newly added text as an incremental delta,
    // matching the token-by-token contract of the CLI and Ollama paths.
    static func runStreaming(prompt: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else { throw ModelError.unavailable(reason ?? "Apple Intelligence is not available.") }
            let session = LanguageModelSession()
            var soFar = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                let cumulative = snapshot.content
                if cumulative == soFar { continue }
                let common = cumulative.commonPrefix(with: soFar)
                let delta = String(cumulative.dropFirst(common.count))
                if !delta.isEmpty { await onDelta(delta) }
                soFar = cumulative
            }
            return soFar.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw ModelError.unavailable("Apple Intelligence is not available on this Mac.")
    }
}
