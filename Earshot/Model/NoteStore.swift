import Foundation
import Combine

// Notes are folders of plain files the user owns:
//   <base>/notes/<uuid>/meta.json, transcript.jsonl, note.md, summary.md, chat.jsonl
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [NoteMeta] = []
    @Published var revision: Int = 0   // bump to nudge detail views after file writes

    let baseDir: URL

    private var appendHandles: [UUID: FileHandle] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = appSupport.appendingPathComponent("Earshot/notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        reload()
    }

    func dir(for id: UUID) -> URL { baseDir.appendingPathComponent(id.uuidString, isDirectory: true) }

    func reload() {
        var loaded: [NoteMeta] = []
        let contents = (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)) ?? []
        for folder in contents {
            let metaURL = folder.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: metaURL), let meta = try? decoder.decode(NoteMeta.self, from: data) {
                loaded.append(meta)
            }
        }
        notes = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Create / update / delete

    func createNote() -> NoteMeta {
        let meta = NoteMeta.new()
        let folder = dir(for: meta.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        save(meta: meta)
        notes.insert(meta, at: 0)
        return meta
    }

    func save(meta: NoteMeta) {
        let url = dir(for: meta.id).appendingPathComponent("meta.json")
        if let data = try? encoder.encode(meta) { try? data.write(to: url) }
        if let idx = notes.firstIndex(where: { $0.id == meta.id }) { notes[idx] = meta }
        revision += 1
    }

    func meta(id: UUID) -> NoteMeta? { notes.first { $0.id == id } }

    func deleteNote(id: UUID) {
        closeAppendHandle(id: id)
        try? FileManager.default.removeItem(at: dir(for: id))
        notes.removeAll { $0.id == id }
        revision += 1
    }

    // MARK: - Transcript (append-only jsonl)

    func appendSegment(noteID: UUID, _ segment: TranscriptSegment) {
        appendLine(noteID: noteID, file: "transcript.jsonl", value: segment)
    }

    func loadSegments(noteID: UUID) -> [TranscriptSegment] {
        loadLines(noteID: noteID, file: "transcript.jsonl")
    }

    // Rewrites the whole transcript, e.g. after a higher-accuracy pass re-transcribes
    // the recording. Bumps the revision so open note views reload.
    func replaceSegments(noteID: UUID, _ segments: [TranscriptSegment]) {
        closeAppendHandle(id: noteID)
        let url = dir(for: noteID).appendingPathComponent("transcript.jsonl")
        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for segment in segments {
            guard let line = try? lineEncoder.encode(segment) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url)
        revision += 1
    }

    // MARK: - Thoughts (rich text as Codable AttributedString + plain note.md export)

    func saveThoughts(noteID: UUID, _ text: AttributedString) {
        if let data = try? JSONEncoder().encode(text) {
            try? data.write(to: dir(for: noteID).appendingPathComponent("thoughts.json"))
        }
        // Keep a grep-friendly plain copy; this is also what agents read.
        let plain = String(text.characters)
        try? plain.write(to: dir(for: noteID).appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    }

    func loadRichThoughts(noteID: UUID) -> AttributedString {
        let url = dir(for: noteID).appendingPathComponent("thoughts.json")
        if let data = try? Data(contentsOf: url),
           let text = try? JSONDecoder().decode(AttributedString.self, from: data) {
            return text
        }
        return AttributedString(loadThoughts(noteID: noteID))
    }

    func loadThoughts(noteID: UUID) -> String {
        (try? String(contentsOf: dir(for: noteID).appendingPathComponent("note.md"), encoding: .utf8)) ?? ""
    }

    // Rich thoughts with inline images, stored as RTFD (which bundles the images).
    // Always also writes a plain note.md so agents and grep read the text.
    func saveThoughtsAttributed(noteID: UUID, _ attributed: NSAttributedString) {
        let range = NSRange(location: 0, length: attributed.length)
        if let data = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            try? data.write(to: dir(for: noteID).appendingPathComponent("thoughts.rtfd"))
        }
        try? attributed.string.write(to: dir(for: noteID).appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    }

    func loadThoughtsAttributed(noteID: UUID) -> NSAttributedString {
        let rtfd = dir(for: noteID).appendingPathComponent("thoughts.rtfd")
        if let data = try? Data(contentsOf: rtfd),
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            return attributed
        }
        // Migrate an older note that only has the AttributedString/plain form.
        return NSAttributedString(loadRichThoughts(noteID: noteID))
    }

    // MARK: - Attachments (images in assets/, links; listed in attachments.jsonl)

    func assetsDir(for id: UUID) -> URL {
        let url = dir(for: id).appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func appendAttachment(noteID: UUID, _ attachment: Attachment) {
        appendLine(noteID: noteID, file: "attachments.jsonl", value: attachment)
        revision += 1
    }

    func loadAttachments(noteID: UUID) -> [Attachment] {
        loadLines(noteID: noteID, file: "attachments.jsonl")
    }

    // Rewrites the attachment list (used for updates like adding OCR text or deleting).
    func saveAttachments(noteID: UUID, _ attachments: [Attachment]) {
        let url = dir(for: noteID).appendingPathComponent("attachments.jsonl")
        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        let lines = attachments.compactMap { try? lineEncoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: url, atomically: true, encoding: .utf8)
        revision += 1
    }

    func saveSummary(noteID: UUID, _ text: String) {
        try? text.write(to: dir(for: noteID).appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        if var m = meta(id: noteID) {
            m.hasSummary = true
            save(meta: m)
        }
    }

    func loadSummary(noteID: UUID) -> String {
        (try? String(contentsOf: dir(for: noteID).appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
    }

    // MARK: - Saved audio

    func audioURL(noteID: UUID) -> URL {
        dir(for: noteID).appendingPathComponent("audio.m4a")
    }

    func hasAudio(noteID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(noteID: noteID).path)
    }

    // MARK: - Chat

    func appendChat(noteID: UUID, _ message: ChatMessage) {
        appendLine(noteID: noteID, file: "chat.jsonl", value: message)
        revision &+= 1
    }

    func loadChat(noteID: UUID) -> [ChatMessage] {
        loadLines(noteID: noteID, file: "chat.jsonl")
    }

    func clearChat(noteID: UUID) {
        try? FileManager.default.removeItem(at: dir(for: noteID).appendingPathComponent("chat.jsonl"))
        revision &+= 1
    }

    // MARK: - Action items

    private func actionsURL(noteID: UUID) -> URL {
        dir(for: noteID).appendingPathComponent("actions.json")
    }

    func hasActions(noteID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: actionsURL(noteID: noteID).path)
    }

    func loadActions(noteID: UUID) -> [ActionItem] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: actionsURL(noteID: noteID)),
              let items = try? d.decode([ActionItem].self, from: data) else { return [] }
        return items
    }

    func saveActions(noteID: UUID, _ items: [ActionItem]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        if let data = try? e.encode(items) {
            try? data.write(to: actionsURL(noteID: noteID))
        }
        revision &+= 1
    }

    func setActionDone(noteID: UUID, actionID: UUID, done: Bool) {
        var items = loadActions(noteID: noteID)
        guard let idx = items.firstIndex(where: { $0.id == actionID }) else { return }
        items[idx].done = done
        saveActions(noteID: noteID, items)
    }

    // MARK: - Knowledge graph (per-note entities)

    private func graphURL(noteID: UUID) -> URL {
        dir(for: noteID).appendingPathComponent("graph.json")
    }

    func hasGraph(noteID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: graphURL(noteID: noteID).path)
    }

    func loadGraph(noteID: UUID) -> NoteGraph {
        guard let data = try? Data(contentsOf: graphURL(noteID: noteID)),
              let graph = try? JSONDecoder().decode(NoteGraph.self, from: data) else { return .empty }
        return graph
    }

    func saveGraph(noteID: UUID, _ graph: NoteGraph) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        if let data = try? e.encode(graph) {
            try? data.write(to: graphURL(noteID: noteID))
        }
        revision &+= 1
    }

    // MARK: - jsonl helpers

    private func appendLine<T: Encodable>(noteID: UUID, file: String, value: T) {
        let url = dir(for: noteID).appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        guard var data = try? lineEncoder.encode(value) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func loadLines<T: Decodable>(noteID: UUID, file: String) -> [T] {
        let url = dir(for: noteID).appendingPathComponent(file)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lineDecoder = JSONDecoder()
        lineDecoder.dateDecodingStrategy = .iso8601
        return raw.split(separator: "\n").compactMap { line in
            try? lineDecoder.decode(T.self, from: Data(line.utf8))
        }
    }

    private func closeAppendHandle(id: UUID) {
        try? appendHandles[id]?.close()
        appendHandles[id] = nil
    }
}
