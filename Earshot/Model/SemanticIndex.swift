import Foundation
import NaturalLanguage

// Local semantic search across meetings. Uses Apple's on-device sentence
// embeddings (no cloud, no downloads) blended with a keyword score, so a query
// like "the budget decision" finds the right meeting even without those words.
@MainActor
final class SemanticIndex {
    static let shared = SemanticIndex()

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var cache: [UUID: (sig: Int, vec: [Double])] = [:]

    struct Result: Identifiable {
        let noteID: UUID
        let score: Double
        let snippet: String
        var id: UUID { noteID }
    }

    func search(_ query: String, in store: NoteStore, limit: Int = 25) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let queryVec = embedding?.vector(for: q.lowercased())

        var results: [Result] = []
        for note in store.notes {
            let summary = store.loadSummary(noteID: note.id)
            let thoughts = store.loadThoughts(noteID: note.id)
            let text = "\(note.title)\n\(summary)\n\(thoughts)"

            var semantic = 0.0
            if let queryVec, let noteVec = vector(for: note.id, text: text) {
                semantic = max(0, cosine(queryVec, noteVec))
            }
            let keyword = keywordScore(query: q, text: text)
            let score = semantic * 0.7 + keyword * 0.3
            if score > 0.06 {
                results.append(Result(noteID: note.id, score: score,
                                      snippet: snippet(query: q, summary: summary.isEmpty ? thoughts : summary)))
            }
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Internals

    private func vector(for id: UUID, text: String) -> [Double]? {
        let sig = text.hashValue
        if let cached = cache[id], cached.sig == sig { return cached.vec }
        guard let vec = embedding?.vector(for: String(text.prefix(1200)).lowercased()) else { return nil }
        cache[id] = (sig, vec)
        return vec
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private func terms(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }

    private func keywordScore(query: String, text: String) -> Double {
        let t = terms(query)
        guard !t.isEmpty else { return 0 }
        let hay = text.lowercased()
        let hits = t.filter { hay.contains($0) }.count
        return Double(hits) / Double(t.count)
    }

    private func snippet(query: String, summary: String) -> String {
        let wanted = Set(terms(query))
        let sentences = summary
            .split { $0 == "." || $0 == "\n" || $0 == "!" || $0 == "?" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return String(summary.prefix(160)) }
        var best = sentences[0]
        var bestScore = -1
        for s in sentences {
            let low = s.lowercased()
            let score = wanted.filter { low.contains($0) }.count
            if score > bestScore { bestScore = score; best = s }
        }
        return String(best.prefix(180))
    }
}
