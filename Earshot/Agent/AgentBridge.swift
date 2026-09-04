import Foundation
import Combine

// The brain. Earshot has no API keys and no cloud account: it pipes transcripts
// into whatever agent the user already has, in this order of preference:
//   1. Claude Code (`claude -p`)   2. Codex (`codex exec`)   3. Ollama (localhost)
enum AgentKind: String, CaseIterable, Identifiable {
    case auto, claudeCode, codex, ollama, none
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (first available)"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        case .none: return "Off (transcripts only)"
        }
    }
}

struct AgentAvailability {
    var claudePath: String?
    var codexPath: String?
    var ollamaModel: String?

    var summaryLine: String {
        var found: [String] = []
        if claudePath != nil { found.append("Claude Code") }
        if codexPath != nil { found.append("Codex") }
        if let m = ollamaModel { found.append("Ollama (\(m))") }
        return found.isEmpty ? "No local agent found" : found.joined(separator: ", ")
    }
}

@MainActor
final class AgentBridge: ObservableObject {
    @Published var preference: AgentKind {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: "agentPreference") }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel") }
    }
    @Published private(set) var availability = AgentAvailability()
    @Published private(set) var isBusy = false

    init() {
        preference = AgentKind(rawValue: UserDefaults.standard.string(forKey: "agentPreference") ?? "auto") ?? .auto
        ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? ""
        Task { await detect() }
    }

    // MARK: - Detection

    func detect() async {
        var result = AgentAvailability()
        result.claudePath = Self.findExecutable("claude")
        result.codexPath = Self.findExecutable("codex")
        if let models = await Self.ollamaModels() {
            let preferred = ollamaModel
            result.ollamaModel = models.contains(preferred) && !preferred.isEmpty ? preferred : models.first
        }
        availability = result
        if ollamaModel.isEmpty, let m = result.ollamaModel { ollamaModel = m }
    }

    nonisolated static func findExecutable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "\(home)/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to a login shell lookup (slow, once).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) { return out }
        } catch {}
        return nil
    }

    nonisolated static func ollamaModels() async -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        let names = models.compactMap { $0["name"] as? String }
        return names.isEmpty ? nil : names
    }

    // MARK: - Running

    enum AgentError: LocalizedError {
        case noAgent
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAgent: return "No local agent found. Install Claude Code, Codex, or Ollama, or pick one in Settings."
            case .failed(let message): return message
            }
        }
    }

    private func resolveKind() -> AgentKind {
        switch preference {
        case .auto:
            if availability.claudePath != nil { return .claudeCode }
            if availability.codexPath != nil { return .codex }
            if availability.ollamaModel != nil { return .ollama }
            return .none
        default:
            return preference
        }
    }

    var activeAgentName: String {
        switch resolveKind() {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        default: return "no agent"
        }
    }

    func run(prompt: String) async throws -> String {
        let kind = resolveKind()
        isBusy = true
        defer { isBusy = false }
        switch kind {
        case .claudeCode:
            guard let path = availability.claudePath else { throw AgentError.noAgent }
            return try await Self.runProcess(path: path, arguments: ["-p", "--output-format", "text"], stdin: prompt)
        case .codex:
            guard let path = availability.codexPath else { throw AgentError.noAgent }
            return try await Self.runProcess(path: path, arguments: ["exec", "--skip-git-repo-check", "-"], stdin: prompt)
        case .ollama:
            guard let model = availability.ollamaModel ?? (ollamaModel.isEmpty ? nil : ollamaModel) else { throw AgentError.noAgent }
            return try await Self.runOllama(model: model, prompt: prompt)
        case .auto, .none:
            throw AgentError.noAgent
        }
    }

    nonisolated private static func runProcess(path: String, arguments: [String], stdin: String, timeout: TimeInterval = 180) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                let extra = "/opt/homebrew/bin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
                environment["PATH"] = "\(extra):\(environment["PATH"] ?? "/usr/bin:/bin")"
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.temporaryDirectory

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AgentError.failed("Could not launch \(path): \(error.localizedDescription)"))
                    return
                }

                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? stdinPipe.fileHandleForWriting.close()

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0, !out.isEmpty {
                    continuation.resume(returning: out)
                } else {
                    let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = out.isEmpty ? (err.isEmpty ? "The agent returned nothing." : err) : out
                    continuation.resume(throwing: AgentError.failed(String(message.prefix(500))))
                }
            }
        }
    }

    nonisolated private static func runOllama(model: String, prompt: String) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { throw AgentError.noAgent }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String, !text.isEmpty else {
            throw AgentError.failed("Ollama did not return a response.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Prompts

enum AgentPrompts {
    static let styleRules = """
    Style rules: plain text or simple markdown. Do not use em dashes anywhere; use commas or periods instead. Be concrete and concise. Never invent facts that are not in the transcript.
    """

    static func transcriptBlock(segments: [TranscriptSegment], thoughts: String, captures: [Attachment] = []) -> String {
        var lines: [String] = []
        for segment in segments where segment.channel != "system" {
            let who = segment.channel == "me" ? "Me" : "Them"
            lines.append("[\(segment.t.clockString)] \(who): \(segment.text)")
        }
        var block = "TRANSCRIPT (Me = this Mac's user speaking, Them = other people on the call):\n" + lines.joined(separator: "\n")
        if !thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block += "\n\nUSER'S OWN TYPED NOTES DURING THE MEETING:\n" + thoughts
        }
        let ocr = captures.compactMap { capture -> String? in
            guard let text = capture.ocrText, !text.isEmpty else { return nil }
            return "[captured at \(capture.t.clockString)]\n\(text)"
        }
        if !ocr.isEmpty {
            block += "\n\nSCREEN CAPTURES DURING THE MEETING (OCR text from slides or shared screens):\n" + ocr.joined(separator: "\n---\n")
        }
        return block
    }

    static func title(segments: [TranscriptSegment]) -> String {
        let lines = segments.suffix(60).filter { $0.channel != "system" }
            .map { "\($0.channel == "me" ? "Me" : "Them"): \($0.text)" }
        return """
        Based on this meeting transcript so far, reply with ONLY a specific 3 to 6 word title for the meeting. No quotes, no punctuation at the end, no explanation. If there is not enough content yet, reply with exactly: New note

        \(lines.joined(separator: "\n"))
        """
    }

    static func summary(segments: [TranscriptSegment], thoughts: String, captures: [Attachment] = []) -> String {
        """
        You are a meeting notes assistant running locally. Summarize this meeting transcript.

        Output format, exactly:
        Line 1: TITLE: <a specific 3 to 6 word title for this meeting>
        Then a markdown summary with these sections, omitting any section with nothing real to say:
        ## Overview
        Two or three sentences on what the meeting was about and what happened.
        ## Key points
        Bulleted, specific, grounded in the transcript.
        ## Decisions
        Only actual decisions made.
        ## Action items
        Bulleted as "- [owner if known] task". Only real commitments from the transcript.

        \(styleRules)

        \(transcriptBlock(segments: segments, thoughts: thoughts, captures: captures))
        """
    }

    static func chat(question: String, segments: [TranscriptSegment], thoughts: String, summary: String) -> String {
        """
        You are a meeting assistant running locally on this Mac. Answer the user's question using only the meeting content below. If the answer is not in the meeting, say so plainly.

        \(styleRules)

        \(summary.isEmpty ? "" : "EXISTING SUMMARY:\n\(summary)\n")
        \(transcriptBlock(segments: segments, thoughts: thoughts))

        QUESTION: \(question)
        """
    }

    static func whatDidIMiss(segments: [TranscriptSegment]) -> String {
        """
        You are a live meeting assistant running locally on this Mac. The user stepped away or lost focus. In at most five short bullets, catch them up on the most recent part of this ongoing meeting: what is being discussed right now, anything they were asked, and any decisions or action items that just happened.

        \(styleRules)

        \(transcriptBlock(segments: segments.suffix(120), thoughts: ""))
        """
    }

    static func globalAsk(question: String, notes: [(meta: NoteMeta, summary: String)]) -> String {
        var context = ""
        for note in notes {
            context += "MEETING: \(note.meta.title) (\(note.meta.createdAt.formatted(date: .abbreviated, time: .shortened)))\n"
            context += note.summary.isEmpty ? "(no summary)\n\n" : note.summary + "\n\n"
        }
        return """
        You are a meeting memory assistant running locally on this Mac. Below are summaries of the user's recent meetings. Answer their question using only this content. If the answer is not there, say so plainly and name the closest related meeting.

        \(styleRules)

        \(context)
        QUESTION: \(question)
        """
    }
}
