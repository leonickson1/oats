import Foundation

struct NoteMeta: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var hasSummary: Bool
    // True once the user edits the title by hand; auto-titling then backs off.
    var titleLocked: Bool?

    static func new() -> NoteMeta {
        NoteMeta(id: UUID(), title: "New note", createdAt: Date(), duration: 0, hasSummary: false, titleLocked: false)
    }

    var isUntitled: Bool { title == "New note" || title.isEmpty }
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let t: TimeInterval        // seconds since recording start
    let channel: String        // "me" | "them" | "system" (pause markers etc.)
    let text: String

    init(t: TimeInterval, channel: String, text: String) {
        self.id = UUID()
        self.t = t
        self.channel = channel
        self.text = text
    }
}

// An image capture or a link attached to a note.
struct Attachment: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: String           // "image" | "link"
    let value: String          // filename inside assets/, or the URL string
    var title: String?
    var ocrText: String?
    let t: TimeInterval        // seconds into the recording (0 when not recording)
    let addedAt: Date

    init(kind: String, value: String, title: String? = nil, ocrText: String? = nil, t: TimeInterval) {
        self.id = UUID()
        self.kind = kind
        self.value = value
        self.title = title
        self.ocrText = ocrText
        self.t = t
        self.addedAt = Date()
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
