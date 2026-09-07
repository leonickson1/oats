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

// A small, deterministic force-directed layout (no randomness, so the graph is
// stable across redraws). Connected components are found first and each gets
// its own region of the canvas, sized by how many nodes it holds (a weighted
// binary split of the canvas). Every component is then relaxed independently
// inside its region: repulsion between its nodes, spring attraction along its
// edges, gravity to the region's center. Unrelated meetings can never tangle,
// clusters never pile into one corner, and the whole canvas gets used.
enum ForceLayout {
    static func layout(nodes: [GraphNode], edges: [GraphEdge], size: CGSize, iterations: Int = 320) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }

        // Connected components via union-find.
        var parent: [String: String] = [:]
        for node in nodes { parent[node.id] = node.id }
        func root(_ id: String) -> String {
            var r = id
            while let p = parent[r], p != r { r = p }
            var cur = id
            while let p = parent[cur], p != r { parent[cur] = r; cur = p }
            return r
        }
        for edge in edges where parent[edge.a] != nil && parent[edge.b] != nil {
            parent[root(edge.a)] = root(edge.b)
        }
        var members: [String: [String]] = [:]
        for node in nodes { members[root(node.id), default: []].append(node.id) }
        var edgesByComponent: [String: [GraphEdge]] = [:]
        for edge in edges where parent[edge.a] != nil {
            edgesByComponent[root(edge.a), default: []].append(edge)
        }

        // Big components first; ids sorted inside so runs are identical.
        let order = members.keys.sorted { a, b in
            let ca = members[a]!.count, cb = members[b]!.count
            return ca == cb ? a < b : ca > cb
        }
        let comps: [[String]] = order.map { members[$0]!.sorted() }
        let compEdges: [[GraphEdge]] = order.map { edgesByComponent[$0] ?? [] }

        // Carve the canvas into one region per component, area roughly
        // proportional to node count (+3 keeps tiny components visible).
        let weights = comps.map { Double($0.count) + 3 }
        var rects = [CGRect](repeating: .zero, count: comps.count)
        assignRegions(Array(comps.indices), weights: weights,
                      rect: CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10),
                      into: &rects)

        var pos: [String: CGPoint] = [:]
        for (i, ids) in comps.enumerated() {
            relax(ids: ids, edges: compEdges[i], rect: rects[i], iterations: iterations, into: &pos)
        }
        return pos
    }

    // Weighted slice-and-dice: split the component list into two halves of
    // roughly equal weight, divide the rect along its longer side in the same
    // proportion, recurse. Deterministic, and regions keep a sane aspect ratio.
    private static func assignRegions(_ order: [Int], weights: [Double], rect: CGRect, into rects: inout [CGRect]) {
        guard let first = order.first else { return }
        if order.count == 1 {
            rects[first] = rect
            return
        }
        let total = order.reduce(0.0) { $0 + weights[$1] }
        var left: [Int] = [], right: [Int] = []
        var acc = 0.0
        for idx in order {
            if left.isEmpty || acc + weights[idx] <= total * 0.5 {
                left.append(idx); acc += weights[idx]
            } else {
                right.append(idx)
            }
        }
        if right.isEmpty { right.append(left.removeLast()); acc -= weights[right[0]] }
        let frac = CGFloat(max(0.15, min(0.85, acc / total)))
        if rect.width >= rect.height {
            let w = rect.width * frac
            assignRegions(left, weights: weights, rect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), into: &rects)
            assignRegions(right, weights: weights, rect: CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height), into: &rects)
        } else {
            let h = rect.height * frac
            assignRegions(left, weights: weights, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), into: &rects)
            assignRegions(right, weights: weights, rect: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h), into: &rects)
        }
    }

    // One component relaxed inside its own region: circle seed, all-pairs
    // repulsion, springs along edges, gravity to the region center. A lone
    // meeting ends up a tidy starburst; the dense cluster gets the most room.
    private static func relax(ids: [String], edges: [GraphEdge], rect: CGRect, iterations: Int, into pos: inout [String: CGPoint]) {
        let inner = rect.insetBy(dx: min(30, rect.width * 0.12), dy: min(30, rect.height * 0.12))
        let center = CGPoint(x: inner.midX, y: inner.midY)
        let count = ids.count
        if count == 1 {
            pos[ids[0]] = center
            return
        }
        let radius = max(10, min(inner.width, inner.height) * 0.38)
        for (i, id) in ids.enumerated() {
            let angle = (Double(i) / Double(count)) * 2 * .pi
            pos[id] = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }

        let k = max(8, sqrt(max(1, inner.width * inner.height) / Double(count)) * 0.62)
        let repulsion = k * k
        var temperature = max(4, min(inner.width, inner.height) * 0.12)

        for _ in 0..<iterations {
            var disp: [String: CGPoint] = [:]
            for id in ids { disp[id] = .zero }

            // Repulsion between every pair in the component.
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

            // Spring attraction along the component's edges.
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

            // Apply, capped by temperature, pulled gently to the region center
            // and kept inside the region.
            for id in ids {
                guard let d = disp[id], var p = pos[id] else { continue }
                let len = max(0.01, sqrt(d.x * d.x + d.y * d.y))
                p.x += d.x / len * min(len, temperature)
                p.y += d.y / len * min(len, temperature)
                p.x += (center.x - p.x) * 0.015
                p.y += (center.y - p.y) * 0.015
                p.x = min(max(inner.minX, p.x), inner.maxX)
                p.y = min(max(inner.minY, p.y), inner.maxY)
                pos[id] = p
            }
            temperature = max(2, temperature * 0.985)
        }
    }
}
