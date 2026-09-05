import Foundation

// A single to-do pulled out of a meeting. Stored per-note as actions.json so it
// stays a plain file the user owns, and aggregated across meetings in the hub.
struct ActionItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var owner: String?
    var done: Bool
    var createdAt: Date

    init(id: UUID = UUID(), text: String, owner: String? = nil, done: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.owner = owner
        self.done = done
        self.createdAt = createdAt
    }
}

// Parse the model's JSON-array reply into action items, tolerating stray text
// around the array (models sometimes wrap it in prose despite instructions).
enum ActionParsing {
    private struct Raw: Decodable { let text: String; let owner: String? }

    static func parse(_ output: String) -> [ActionItem] {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start < end else { return [] }
        let json = String(output[start...end])
        let decoder = JSONDecoder()
        guard let raws = try? decoder.decode([Raw].self, from: Data(json.utf8)) else { return [] }
        return raws.compactMap { raw in
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let owner = raw.owner?.trimmingCharacters(in: .whitespaces)
            let cleanOwner = (owner == nil || owner!.isEmpty || owner!.lowercased() == "null") ? nil : owner
            return ActionItem(text: text, owner: cleanOwner)
        }
    }
}
