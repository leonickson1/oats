import Foundation
import Combine

// A Space is a workspace: a named collection of meetings (a class, a client, a
// project) with its own chat. Meetings can live in more than one space. Stored
// as plain JSON the user owns, one file per space.
struct Space: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var symbol: String        // an SF Symbol name for the sidebar
    var noteIDs: [UUID]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, symbol: String = "folder", noteIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.noteIDs = noteIDs
        self.createdAt = createdAt
    }
}

@MainActor
final class SpaceStore: ObservableObject {
    @Published private(set) var spaces: [Space] = []

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
        dir = appSupport.appendingPathComponent("Earshot/spaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Space] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let space = try? decoder.decode(Space.self, from: data) {
                loaded.append(space)
            }
        }
        spaces = loaded.sorted { $0.createdAt < $1.createdAt }
    }

    func space(id: UUID) -> Space? { spaces.first { $0.id == id } }

    func spaces(containing noteID: UUID) -> [Space] {
        spaces.filter { $0.noteIDs.contains(noteID) }
    }

    @discardableResult
    func create(name: String, symbol: String = "folder") -> Space {
        let space = Space(name: name.isEmpty ? "New space" : name, symbol: symbol)
        save(space)
        return space
    }

    func save(_ space: Space) {
        let url = dir.appendingPathComponent("\(space.id.uuidString).json")
        if let data = try? encoder.encode(space) { try? data.write(to: url) }
        if let idx = spaces.firstIndex(where: { $0.id == space.id }) {
            spaces[idx] = space
        } else {
            spaces.append(space)
        }
        spaces.sort { $0.createdAt < $1.createdAt }
    }

    func rename(id: UUID, to name: String, symbol: String? = nil) {
        guard var space = space(id: id) else { return }
        space.name = name.isEmpty ? space.name : name
        if let symbol { space.symbol = symbol }
        save(space)
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
        spaces.removeAll { $0.id == id }
    }

    func add(noteID: UUID, to spaceID: UUID) {
        guard var space = space(id: spaceID) else { return }
        if !space.noteIDs.contains(noteID) { space.noteIDs.append(noteID); save(space) }
    }

    func remove(noteID: UUID, from spaceID: UUID) {
        guard var space = space(id: spaceID) else { return }
        space.noteIDs.removeAll { $0 == noteID }
        save(space)
    }

    func toggle(noteID: UUID, in spaceID: UUID) {
        guard let space = space(id: spaceID) else { return }
        if space.noteIDs.contains(noteID) { remove(noteID: noteID, from: spaceID) }
        else { add(noteID: noteID, to: spaceID) }
    }
}
