import SwiftUI

// The knowledge graph across every meeting, built entirely on-device: people,
// projects, topics and orgs, linked to the meetings they appear in. A native
// force-directed graph (no servers, no Neo4j) plus a directory list.
struct KnowledgeGraphView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder

    enum Tab: String, CaseIterable { case graph = "Graph"; case directory = "Directory" }
    @State private var tab: Tab = .graph
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedID: String?
    @State private var focusKind: EntityKind?
    @State private var expandedEntities: Set<String> = []
    @State private var canvasSize: CGSize = .zero
    @State private var scanning = false
    @State private var scanProgress = ""

    private var graph: KnowledgeGraph {
        _ = store.revision
        let input = store.notes.map { (id: $0.id, title: $0.title, graph: store.loadGraph(noteID: $0.id)) }
        return GraphBuilder.build(notes: input)
    }

    // Notes with no extracted entities yet, so re-analyzing works even if a note
    // was scanned before and came back empty.
    private var unscanned: [NoteMeta] {
        store.notes.filter { store.loadGraph(noteID: $0.id).entities.isEmpty }
    }

    var body: some View {
        let g = graph
        return VStack(spacing: 0) {
            GlassSegmented(options: [(Tab.graph, "Graph"), (Tab.directory, "Directory")], selection: $tab)
                .padding(.vertical, 10)
            Divider().opacity(0.4)

            if g.isEmpty {
                emptyState
            } else if tab == .graph {
                graphCanvas(g)
            } else {
                directory(g)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarTitleLabel(text: "Knowledge graph")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { scan() } label: {
                    if scanning { Label(scanProgress, systemImage: "hourglass") }
                    else { Label("Analyze meetings", systemImage: "sparkles") }
                }
                .disabled(scanning || unscanned.isEmpty)
                .help(unscanned.isEmpty ? "All meetings analyzed" : "Extract people and topics from meetings not yet analyzed")
            }
        }
    }

    // MARK: - Graph canvas

    private func graphCanvas(_ g: KnowledgeGraph) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })
        return GeometryReader { geo in
            ZStack {
                Canvas { context, _ in
                    for edge in g.edges {
                        guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                        let alpha = edgeAlpha(edge, byID: byID)
                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        context.stroke(path, with: .color(.gray.opacity(alpha)),
                                       lineWidth: alpha > 0.2 ? 1.2 : 0.6)
                    }
                }
                ForEach(g.nodes) { node in
                    nodeView(node)
                        .opacity(nodeOpacity(node))
                        .position(positions[node.id] ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                        .gesture(
                            DragGesture(coordinateSpace: .named("graph"))
                                .onChanged { value in positions[node.id] = value.location }
                        )
                        .onTapGesture { selectedID = (selectedID == node.id ? nil : node.id) }
                }
            }
            .coordinateSpace(name: "graph")
            .contentShape(Rectangle())
            .onTapGesture { selectedID = nil }
            .overlay(alignment: .topTrailing) {
                if let id = selectedID, let node = g.nodes.first(where: { $0.id == id }) {
                    detailCard(node)
                        .padding(16)
                }
            }
            .overlay(alignment: .bottomLeading) { legend.padding(16) }
            .onAppear {
                canvasSize = geo.size
                relayout(g, size: geo.size)
            }
            .onChange(of: geo.size) { _, new in
                canvasSize = new
                if positions.isEmpty { relayout(g, size: new) }
            }
            .onChange(of: store.revision) {
                relayout(g, size: geo.size)
            }
        }
    }

    private func nodeView(_ node: GraphNode) -> some View {
        let r = radius(node)
        let selected = selectedID == node.id
        return VStack(spacing: 3) {
            Circle()
                .fill(color(node.kind))
                .frame(width: r * 2, height: r * 2)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0.25), lineWidth: selected ? 2 : 0.5))
                .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 4)
            if node.weight >= 2 || selected || isMeeting(node) {
                Text(node.label)
                    .font(.system(size: 9, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func detailCard(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                KindBadge(color: color(node.kind), symbol: nodeSymbol(node.kind), size: 22)
                Text(node.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
            }
            Text(kindLabel(node.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Divider()
            if isMeeting(node), let noteID = node.noteIDs.first {
                Button { app.openNote(id: noteID) } label: {
                    Label("Open meeting", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            } else {
                Text(node.noteIDs.count == 1 ? "In 1 meeting" : "In \(node.noteIDs.count) meetings")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                ForEach(node.noteIDs.prefix(8), id: \.self) { nid in
                    if let meta = store.meta(id: nid) {
                        Button { app.openNote(id: nid) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform").font(.system(size: 10))
                                Text(meta.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 244, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    // A working filter, not a decorative key: tap a category to focus the graph
    // on just those nodes, tap again to clear.
    private var legend: some View {
        HStack(spacing: 4) {
            ForEach(EntityKind.allCases, id: \.self) { kind in
                let on = focusKind == kind
                Button {
                    withAnimation(Motion.quick) {
                        focusKind = (focusKind == kind ? nil : kind)
                    }
                } label: {
                    HStack(spacing: 7) {
                        KindBadge(color: color(.entity(kind)), symbol: kindSymbol(kind), size: 18)
                        Text(pluralKind(kind))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(on ? .primary : .secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.primary.opacity(0.10))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(on ? "Show everything" : "Focus on \(pluralKind(kind).lowercased())")
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Focus dimming

    private func nodeOpacity(_ node: GraphNode) -> Double {
        guard let fk = focusKind else { return 1 }
        switch node.kind {
        case .meeting: return 0.55                 // meetings stay as faint anchors
        case .entity(let k): return k == fk ? 1 : 0.12
        }
    }

    private func edgeAlpha(_ edge: GraphEdge, byID: [String: GraphNode]) -> Double {
        let selBase = (selectedID == nil || edge.a == selectedID || edge.b == selectedID) ? 0.35 : 0.10
        guard let fk = focusKind else { return selBase }
        let touches = isEntityOfKind(byID[edge.a], fk) || isEntityOfKind(byID[edge.b], fk)
        return touches ? selBase : 0.04
    }

    private func isEntityOfKind(_ node: GraphNode?, _ kind: EntityKind) -> Bool {
        if case .entity(let k) = node?.kind { return k == kind }
        return false
    }

    // MARK: - Directory

    private func directory(_ g: KnowledgeGraph) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(EntityKind.allCases, id: \.self) { kind in
                    let entities = g.nodes
                        .filter { $0.kind == .entity(kind) }
                        .sorted { $0.weight > $1.weight }
                    if !entities.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(pluralKind(kind))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("\(entities.count)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.5), in: Capsule())
                            }
                            GlassEffectContainer(spacing: 8) {
                                VStack(spacing: 8) {
                                    ForEach(entities) { entity in
                                        entityAccordion(entity, kind: kind)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // One entity as a glass accordion: tap to reveal the meetings it appears in.
    private func entityAccordion(_ entity: GraphNode, kind: EntityKind) -> some View {
        let open = expandedEntities.contains(entity.id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(Motion.standard) {
                    if open { expandedEntities.remove(entity.id) } else { expandedEntities.insert(entity.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    KindBadge(color: color(.entity(kind)), symbol: kindSymbol(kind), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entity.label)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Text(entity.noteIDs.count == 1 ? "1 meeting" : "\(entity.noteIDs.count) meetings")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Divider().opacity(0.35).padding(.horizontal, 12)
                VStack(spacing: 1) {
                    ForEach(entity.noteIDs, id: \.self) { nid in
                        if let meta = store.meta(id: nid) {
                            meetingSubRow(meta)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 5)
                .padding(.bottom, 8)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func meetingSubRow(_ meta: NoteMeta) -> some View {
        Button { app.openNote(id: meta.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(meta.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(meta.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(HomeRowButtonStyle())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Your knowledge graph is empty")
                .font(.system(size: 15, weight: .semibold, design: .serif))
            Text(store.notes.isEmpty
                 ? "Load sample meetings to see the graph, or record a few and it fills in."
                 : (unscanned.isEmpty
                    ? "New meetings are added to the graph automatically."
                    : "Analyze your meetings to map the people, projects and topics across them."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                if !unscanned.isEmpty {
                    Button { scan() } label: {
                        Label(scanning ? scanProgress : "Analyze \(unscanned.count) meeting\(unscanned.count == 1 ? "" : "s")", systemImage: "sparkles")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(scanning)
                }
                if !DemoData.isLoaded {
                    Button {
                        DemoData.load(into: store)
                    } label: {
                        Label("Load sample meetings", systemImage: "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(scanning)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func relayout(_ g: KnowledgeGraph, size: CGSize) {
        guard size.width > 1, size.height > 1, !g.nodes.isEmpty else { return }
        positions = ForceLayout.layout(nodes: g.nodes, edges: g.edges, size: size)
    }

    private func radius(_ node: GraphNode) -> CGFloat {
        if isMeeting(node) { return 7 }
        return 5 + min(9, CGFloat(node.weight) * 1.6)
    }

    private func isMeeting(_ node: GraphNode) -> Bool {
        if case .meeting = node.kind { return true }
        return false
    }

    private func color(_ kind: NodeKind) -> Color {
        switch kind {
        case .meeting: return .gray
        case .entity(.person): return Theme.record
        case .entity(.project): return Color(red: 0.30, green: 0.55, blue: 0.45)
        case .entity(.topic): return Color(red: 0.42, green: 0.45, blue: 0.72)
        case .entity(.org): return Color(red: 0.80, green: 0.60, blue: 0.25)
        }
    }

    private func kindLabel(_ kind: NodeKind) -> String {
        switch kind {
        case .meeting: return "Meeting"
        case .entity(let e): return e.rawValue.capitalized
        }
    }

    private func kindSymbol(_ kind: EntityKind) -> String {
        switch kind {
        case .person: return "person.fill"
        case .project: return "square.stack.3d.up.fill"
        case .topic: return "tag.fill"
        case .org: return "building.2.fill"
        }
    }

    private func nodeSymbol(_ kind: NodeKind) -> String {
        switch kind {
        case .meeting: return "waveform"
        case .entity(let e): return kindSymbol(e)
        }
    }

    private func pluralKind(_ kind: EntityKind) -> String {
        switch kind {
        case .person: return "People"
        case .project: return "Projects"
        case .topic: return "Topics"
        case .org: return "Organizations"
        }
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let todo = unscanned
            for (index, note) in todo.enumerated() {
                scanProgress = "Analyzing \(index + 1) of \(todo.count)"
                await recorder.extractGraph(noteID: note.id)
            }
            scanning = false
            scanProgress = ""
        }
    }
}

// A small circular badge: a colored disc with a white SF Symbol inside. Used for
// the graph legend, the directory, and node detail so every kind reads the same.
struct KindBadge: View {
    let color: Color
    let symbol: String
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
