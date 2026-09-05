import Foundation
import CoreGraphics

// What the local model pulls out of one meeting. Stored per-note as graph.json,
// then merged across all meetings into one knowledge graph at read time.
enum EntityKind: String, Codable, CaseIterable {
    case person, project, topic, org
}

struct GraphEntity: Codable, Equatable {
    var name: String
    var kind: EntityKind
}

struct GraphRelation: Codable, Equatable {
    var from: String
    var to: String
    var type: String
}

struct NoteGraph: Codable, Equatable {
    var entities: [GraphEntity]
    var relations: [GraphRelation]

    static let empty = NoteGraph(entities: [], relations: [])
}

// Tolerant parse of the model's JSON reply (may be wrapped in prose/fences).
enum GraphParsing {
    private struct Raw: Decodable {
        struct E: Decodable { let name: String; let kind: String }
        struct R: Decodable { let from: String; let to: String; let type: String? }
        let entities: [E]?
        let relations: [R]?
    }

    static func parse(_ output: String) -> NoteGraph {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end else { return .empty }
        let json = String(output[start...end])
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return .empty }
        let entities: [GraphEntity] = (raw.entities ?? []).compactMap { e in
            let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let kind = EntityKind(rawValue: e.kind.lowercased()) else { return nil }
            return GraphEntity(name: name, kind: kind)
        }
        let relations: [GraphRelation] = (raw.relations ?? []).compactMap { r in
            let from = r.from.trimmingCharacters(in: .whitespaces)
            let to = r.to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return GraphRelation(from: from, to: to, type: (r.type ?? "").trimmingCharacters(in: .whitespaces))
        }
        return NoteGraph(entities: entities, relations: relations)
    }
}

// MARK: - The merged graph

enum NodeKind: Equatable {
    case meeting
    case entity(EntityKind)
}

struct GraphNode: Identifiable, Equatable {
    let id: String
    var label: String
    var kind: NodeKind
    var noteIDs: [UUID]
    var weight: Int
}

struct GraphEdge: Identifiable, Equatable {
    let id: String
    let a: String
    let b: String
    var weight: Int
}

struct KnowledgeGraph {
    var nodes: [GraphNode]
    var edges: [GraphEdge]

    var isEmpty: Bool { nodes.isEmpty }
}

// Merge every note's extracted entities into a single graph: a node per meeting,
// a node per unique entity (merged by lowercased name + kind), a meeting-to-entity
// edge for each mention, and entity-to-entity edges for stated relationships.
enum GraphBuilder {
    static func build(notes: [(id: UUID, title: String, graph: NoteGraph)]) -> KnowledgeGraph {
        var nodes: [String: GraphNode] = [:]
        var edges: [String: GraphEdge] = [:]

        func entityID(_ e: GraphEntity) -> String { "\(e.kind.rawValue):\(e.name.lowercased())" }
        func bumpEdge(_ a: String, _ b: String) {
            let key = [a, b].sorted().joined(separator: "|")
            if var e = edges[key] { e.weight += 1; edges[key] = e }
            else { edges[key] = GraphEdge(id: key, a: a, b: b, weight: 1) }
        }

        for note in notes {
            let noteGraph = note.graph
            guard !noteGraph.entities.isEmpty else { continue }
            let meetingID = "meeting:\(note.id.uuidString)"
            nodes[meetingID] = GraphNode(id: meetingID, label: note.title, kind: .meeting, noteIDs: [note.id], weight: 1)

            var nameToID: [String: String] = [:]
            for entity in noteGraph.entities {
                let eid = entityID(entity)
                nameToID[entity.name.lowercased()] = eid
                if var existing = nodes[eid] {
                    if !existing.noteIDs.contains(note.id) { existing.noteIDs.append(note.id) }
                    existing.weight += 1
                    nodes[eid] = existing
                } else {
                    nodes[eid] = GraphNode(id: eid, label: entity.name, kind: .entity(entity.kind), noteIDs: [note.id], weight: 1)
                }
                bumpEdge(meetingID, eid)
            }

            for relation in noteGraph.relations {
                guard let a = nameToID[relation.from.lowercased()],
                      let b = nameToID[relation.to.lowercased()], a != b else { continue }
                bumpEdge(a, b)
            }
        }

        return KnowledgeGraph(nodes: Array(nodes.values), edges: Array(edges.values))
    }
}

// A small, deterministic force-directed layout. Positions are seeded on a circle
// (no randomness, so the graph is stable across redraws), then relaxed with
// repulsion between all nodes and spring attraction along edges.
enum ForceLayout {
    static func layout(nodes: [GraphNode], edges: [GraphEdge], size: CGSize, iterations: Int = 320) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.34
        let count = nodes.count

        var pos: [String: CGPoint] = [:]
        for (i, node) in nodes.enumerated() {
            let angle = (Double(i) / Double(count)) * 2 * .pi
            pos[node.id] = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        guard count > 1 else { return pos }

        let ids = nodes.map { $0.id }
        let k = Double(min(size.width, size.height)) / sqrt(Double(count)) * 0.55  // ideal spacing
        let repulsion = k * k
        var temperature = Double(min(size.width, size.height)) * 0.10

        for _ in 0..<iterations {
            var disp: [String: CGPoint] = [:]
            for id in ids { disp[id] = .zero }

            // Repulsion between every pair.
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let a = ids[i], b = ids[j]
                    guard let pa = pos[a], let pb = pos[b] else { continue }
                    var dx = pa.x - pb.x
                    var dy = pa.y - pb.y
                    var dist = sqrt(dx * dx + dy * dy)
                    if dist < 0.01 { dx = 0.5; dy = 0.5; dist = 0.7 }
                    let force = repulsion / dist
                    let fx = dx / dist * force
                    let fy = dy / dist * force
                    disp[a] = CGPoint(x: disp[a]!.x + fx, y: disp[a]!.y + fy)
                    disp[b] = CGPoint(x: disp[b]!.x - fx, y: disp[b]!.y - fy)
                }
            }

            // Spring attraction along edges.
            for edge in edges {
                guard let pa = pos[edge.a], let pb = pos[edge.b] else { continue }
                let dx = pa.x - pb.x
                let dy = pa.y - pb.y
                let dist = max(0.01, sqrt(dx * dx + dy * dy))
                let force = (dist * dist) / k
                let fx = dx / dist * force
                let fy = dy / dist * force
                disp[edge.a] = CGPoint(x: disp[edge.a]!.x - fx, y: disp[edge.a]!.y - fy)
                disp[edge.b] = CGPoint(x: disp[edge.b]!.x + fx, y: disp[edge.b]!.y + fy)
            }

            // Apply, capped by temperature, then pull gently to center.
            for id in ids {
                guard let d = disp[id], var p = pos[id] else { continue }
                let len = max(0.01, sqrt(d.x * d.x + d.y * d.y))
                p.x += d.x / len * min(len, temperature)
                p.y += d.y / len * min(len, temperature)
                p.x += (center.x - p.x) * 0.012
                p.y += (center.y - p.y) * 0.012
                p.x = min(max(24, p.x), size.width - 24)
                p.y = min(max(24, p.y), size.height - 24)
                pos[id] = p
            }
            temperature = max(2, temperature * 0.985)
        }
        return pos
    }
}
