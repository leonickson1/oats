import Foundation

struct NoteMeta: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var hasSummary: Bool

    static func new() -> NoteMeta {
        NoteMeta(id: UUID(), title: "New note", createdAt: Date(), duration: 0, hasSummary: false)
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let t: TimeInterval        // seconds since recording start
    let channel: String        // "me" | "them"
    let text: String

    init(t: TimeInterval, channel: String, text: String) {
        self.id = UUID()
        self.t = t
        self.channel = channel
        self.text = text
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String           // "user" | "assistant"
    let text: String
    let at: Date

    init(role: String, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.at = Date()
    }
}

extension TimeInterval {
    var clockString: String {
        let s = Int(self)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
