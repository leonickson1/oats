import Foundation
import Combine

// One saved Ask conversation. noteID/noteTitle tie it to the meeting that was in
// focus when it started (nil = a general chat). noteTitle is kept denormalized so
// the group still reads well if the note is later deleted.
struct AskSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var noteID: UUID?
    var noteTitle: String?
    var spaceID: UUID?

    init(id: UUID, title: String, createdAt: Date, updatedAt: Date, messages: [ChatMessage],
         noteID: UUID? = nil, noteTitle: String? = nil, spaceID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.spaceID = spaceID
    }
}

// Persists Ask popup conversations so they are never lost and can be reopened in
// the main window. Each session is a JSON file in App Support/Earshot/ask/.
@MainActor
final class AskStore: ObservableObject {
    @Published private(set) var sessions: [AskSession] = []

    private let dir: URL
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
        dir = appSupport.appendingPathComponent("Earshot/ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [AskSession] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let session = try? decoder.decode(AskSession.self, from: data) {
                loaded.append(session)
            }
        }
        sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ session: AskSession) {
        let url = dir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? encoder.encode(session) { try? data.write(to: url) }
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    func session(id: UUID) -> AskSession? { sessions.first { $0.id == id } }

    // Rename a chat. Keeps updatedAt (and therefore list order) unchanged.
    func rename(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var session = session(id: id) else { return }
        session.title = trimmed
        let url = dir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? encoder.encode(session) { try? data.write(to: url) }
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) { sessions[idx] = session }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
        sessions.removeAll { $0.id == id }
    }

    // Wipes every saved conversation. Used by the Settings reset.
    func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files { try? FileManager.default.removeItem(at: url) }
        sessions.removeAll()
    }
}
