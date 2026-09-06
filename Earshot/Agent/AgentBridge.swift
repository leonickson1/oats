import Foundation
import Combine

// The brain. Earshot has no API keys and no cloud account: it pipes transcripts
// into whatever agent the user already has, in this order of preference:
//   1. Claude Code (`claude -p`)   2. Codex (`codex exec`)   3. Ollama (localhost)
enum AgentKind: String, CaseIterable, Identifiable {
    case auto, claudeCode, codex, ollama, apple, none
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (first available)"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        case .apple: return "Apple Intelligence"
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
    // Which Claude model the `claude` CLI should use. Empty = the CLI's default.
    @Published var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }
    @Published private(set) var availability = AgentAvailability()
    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var isBusy = false
    // Apple's built-in on-device model (macOS 26 Apple Intelligence).
    @Published private(set) var appleAvailable = false
    @Published private(set) var appleReason: String?

    // Model aliases the Claude Code CLI accepts via --model.
    let claudeModels = ["opus", "sonnet", "haiku"]

    init() {
        preference = AgentKind(rawValue: UserDefaults.standard.string(forKey: "agentPreference") ?? "auto") ?? .auto
        ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? ""
        claudeModel = UserDefaults.standard.string(forKey: "claudeModel") ?? ""
        Task { await detect() }
    }

    private var claudeArguments: [String] {
        var args = ["-p", "--output-format", "text"]
        if !claudeModel.isEmpty { args += ["--model", claudeModel] }
        return args
    }

    // MARK: - Detection

    func detect() async {
        var result = AgentAvailability()
        result.claudePath = Self.findExecutable("claude")
        result.codexPath = Self.findExecutable("codex")
        appleAvailable = AppleModel.isAvailable
        appleReason = AppleModel.reason
        if let models = await Self.ollamaModels() {
            ollamaModels = models
            let preferred = ollamaModel
            result.ollamaModel = models.contains(preferred) && !preferred.isEmpty ? preferred : models.first
        } else {
            ollamaModels = []
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
            if appleAvailable { return .apple }
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
        case .apple: return "Apple Intelligence"
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
            return try await Self.runProcess(path: path, arguments: claudeArguments, stdin: prompt)
        case .codex:
            guard let path = availability.codexPath else { throw AgentError.noAgent }
            return try await Self.runProcess(path: path, arguments: ["exec", "--skip-git-repo-check", "-"], stdin: prompt)
        case .ollama:
            guard let model = availability.ollamaModel ?? (ollamaModel.isEmpty ? nil : ollamaModel) else { throw AgentError.noAgent }
            return try await Self.runOllama(model: model, prompt: prompt)
        case .apple:
            return try await AppleModel.run(prompt: prompt)
        case .auto, .none:
            throw AgentError.noAgent
        }
    }

    // Streaming variant: onDelta fires (on the main actor) as text arrives, so
    // answers appear token by token instead of after a long silent wait.
    func runStreaming(prompt: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        let kind = resolveKind()
        isBusy = true
        defer { isBusy = false }
        switch kind {
        case .claudeCode:
            guard let path = availability.claudePath else { throw AgentError.noAgent }
            return try await Self.streamProcess(path: path, arguments: claudeArguments, stdin: prompt, onDelta: onDelta)
        case .codex:
            guard let path = availability.codexPath else { throw AgentError.noAgent }
            return try await Self.streamProcess(path: path, arguments: ["exec", "--skip-git-repo-check", "-"], stdin: prompt, onDelta: onDelta)
        case .ollama:
            guard let model = availability.ollamaModel ?? (ollamaModel.isEmpty ? nil : ollamaModel) else { throw AgentError.noAgent }
            return try await Self.streamOllama(model: model, prompt: prompt, onDelta: onDelta)
        case .apple:
            return try await AppleModel.runStreaming(prompt: prompt, onDelta: onDelta)
        case .auto, .none:
            throw AgentError.noAgent
        }
    }

    // MARK: - Ollama model download

    // Pull a model into Ollama, reporting progress (0...1, or -1 while indeterminate)
    // and a short status line. Refreshes the model list when finished.
    func pullOllama(model: String, onProgress: @escaping @MainActor (Double, String) -> Void) async throws {
        guard let url = URL(string: "http://127.0.0.1:11434/api/pull") else { throw AgentError.noAgent }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AgentError.failed("Ollama is not running. Open the Ollama app, then try again.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentError.failed("Ollama could not start the download. Is it running?")
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let message = json["error"] as? String { throw AgentError.failed(message) }
            let status = json["status"] as? String ?? ""
            if let total = json["total"] as? Double, let completed = json["completed"] as? Double, total > 0 {
                await onProgress(completed / total, status)
            } else {
                await onProgress(-1, status)
            }
            if status.lowercased() == "success" { break }
        }
        await detect()
    }

    nonisolated private static func streamProcess(path: String, arguments: [String], stdin: String, timeout: TimeInterval = 180, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
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

        let (stream, continuation) = AsyncStream<String>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else if let chunk = String(data: data, encoding: .utf8) {
                continuation.yield(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            throw AgentError.failed("Could not launch \(path): \(error.localizedDescription)")
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        var accumulated = ""
        for await chunk in stream {
            accumulated += chunk
            await onDelta(chunk)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        process.waitUntilExit()
        watchdog.cancel()

        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !trimmed.isEmpty {
            return trimmed
        }
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw AgentError.failed(String((trimmed.isEmpty ? (err.isEmpty ? "The agent returned nothing." : err) : trimmed).prefix(500)))
    }

    nonisolated private static func streamOllama(model: String, prompt: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { throw AgentError.noAgent }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": true,
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentError.failed("Ollama request failed.")
        }
        var accumulated = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let piece = json["response"] as? String else { continue }
            if !piece.isEmpty {
                accumulated += piece
                await onDelta(piece)
            }
            if json["done"] as? Bool == true { break }
        }
        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentError.failed("Ollama did not return a response.") }
        return trimmed
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

    static func transcriptBlock(segments: [TranscriptSegment], thoughts: String, captures: [Attachment] = [], assetsDir: URL? = nil) -> String {
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
        // Hand file-capable models (Claude Code, Codex) the actual image paths so
        // they can open and see the slides directly, not just the OCR text.
        if let assetsDir {
            let paths = captures.compactMap { capture -> String? in
                guard capture.kind == "image" else { return nil }
                return "[captured at \(capture.t.clockString)] " + assetsDir.appendingPathComponent(capture.value).path
            }
            if !paths.isEmpty {
                block += "\n\nSCREEN CAPTURE IMAGE FILES (if you can open image files, view these to see the slides and charts directly):\n" + paths.joined(separator: "\n")
            }
        }
        return block
    }

    static func title(segments: [TranscriptSegment], summary: String = "") -> String {
        let lines = segments.suffix(60).filter { $0.channel != "system" }
            .map { "\($0.channel == "me" ? "Me" : "Them"): \($0.text)" }
        var source = lines.joined(separator: "\n")
        if !summary.isEmpty { source += "\n\nSUMMARY:\n\(summary)" }
        return """
        Based on this meeting transcript so far, reply with ONLY a specific 3 to 6 word title for the meeting. Use only names and topics that actually appear in it. No quotes, no punctuation at the end, no explanation, no markdown. If there is not enough content yet, reply with exactly: New note

        \(source)
        """
    }

    static func summary(segments: [TranscriptSegment], thoughts: String, captures: [Attachment] = [], assetsDir: URL? = nil) -> String {
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

        Grounding rules, non-negotiable:
        - Every sentence must be supported by a specific line of the transcript or the user's notes. Do not pad, generalize, or invent anything.
        - Never write placeholders like [Owner], [Team Member] or [Name]. Use real names from the transcript, or leave the owner off.
        - If a section has nothing real to say, omit that section entirely.
        - If the whole meeting was too short or trivial to summarize, output only the Overview section: one sentence saying what little was actually said.

        \(styleRules)

        \(transcriptBlock(segments: segments, thoughts: thoughts, captures: captures, assetsDir: assetsDir))
        """
    }

    // Pull out concrete to-dos as strict JSON so we can track and check them off.
    // The transcript and the user's typed thoughts are always the ground truth;
    // the summary rides along as a hint, never as the only source.
    static func actionItems(summary: String, segments: [TranscriptSegment], thoughts: String = "") -> String {
        var source = transcriptBlock(segments: segments, thoughts: thoughts)
        if !summary.isEmpty { source += "\n\nSUMMARY ALREADY WRITTEN FOR THIS MEETING:\n\(summary)" }
        return """
        Extract the concrete action items and commitments from this meeting. Only real tasks someone in the meeting actually agreed to do, or tasks the user wrote in their own notes. Not general discussion, and nothing inferred or invented.

        Respond with ONLY a JSON array, no prose, no code fences. Each element:
        {"text": "the task, imperative and specific", "owner": "person responsible or null if unknown"}
        Rules: the owner must be a real name that appears in the meeting, otherwise null. Never invent placeholder names. If there are no real action items, respond with exactly: []

        \(source)
        """
    }

    // Pull out the people, projects, topics and orgs (plus how they relate) so we
    // can build a knowledge graph across meetings. Strict JSON.
    static func entities(summary: String, segments: [TranscriptSegment]) -> String {
        let source = summary.isEmpty
            ? transcriptBlock(segments: segments, thoughts: "")
            : "SUMMARY:\n\(summary)"
        return """
        From this meeting, extract the key entities and how they relate.

        Respond with ONLY a JSON object, no prose, no code fences:
        {
          "entities": [{"name": "...", "kind": "person|project|topic|org"}],
          "relations": [{"from": "entity name", "to": "entity name", "type": "short verb phrase"}]
        }
        Rules: use real names actually present, not generic words. Merge obvious duplicates. Keep it to the 12 most important entities. Relations must connect two names from the entities list. If nothing meaningful, respond with {"entities": [], "relations": []}.

        \(source)
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

    // The summonable Ask popup: a general assistant that can also draw on the
    // user's recent meetings, and keeps the running conversation in context.
    static func ask(question: String, history: [ChatMessage], notes: [(meta: NoteMeta, summary: String)]) -> String {
        var context = ""
        for note in notes where !note.summary.isEmpty {
            context += "MEETING: \(note.meta.title) (\(note.meta.createdAt.formatted(date: .abbreviated, time: .shortened)))\n\(note.summary)\n\n"
        }
        var convo = ""
        for message in history {
            convo += (message.role == "user" ? "User: " : "Assistant: ") + message.text + "\n"
        }
        return """
        You are Earshot's assistant, running locally on this Mac. Answer the user's question directly and helpfully. If the question is about their meetings, use the meeting summaries below; otherwise just answer normally. Format the answer in clean markdown (headings, bullets, bold where it helps).

        \(styleRules)

        \(context.isEmpty ? "" : "RECENT MEETINGS (use only if relevant):\n\(context)")
        \(convo.isEmpty ? "" : "CONVERSATION SO FAR:\n\(convo)")
        QUESTION: \(question)
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
