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

    // MARK: - Thoughts / summary (markdown)

    func saveThoughts(noteID: UUID, _ text: String) {
        try? text.write(to: dir(for: noteID).appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    }

    func loadThoughts(noteID: UUID) -> String {
        (try? String(contentsOf: dir(for: noteID).appendingPathComponent("note.md"), encoding: .utf8)) ?? ""
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

    // MARK: - Chat

    func appendChat(noteID: UUID, _ message: ChatMessage) {
        appendLine(noteID: noteID, file: "chat.jsonl", value: message)
    }

    func loadChat(noteID: UUID) -> [ChatMessage] {
        loadLines(noteID: noteID, file: "chat.jsonl")
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
