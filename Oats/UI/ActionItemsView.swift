import SwiftUI

// One place for every to-do Oats found across your meetings. Check them off,
// jump to the meeting they came from, or scan meetings that were never analyzed.
struct ActionItemsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var recorder: MeetingRecorder

    @State private var showCompleted = false
    @State private var scanning = false
    @State private var scanProgress = ""

    private struct Group: Identifiable {
        let note: NoteMeta
        var items: [ActionItem]
        var id: UUID { note.id }
    }

    private var groups: [Group] {
        _ = store.revision   // recompute when actions change on disk
        return store.notes.compactMap { note in
            let items = store.loadActions(noteID: note.id)
                .filter { showCompleted || !$0.done }
                .sorted { !$0.done && $1.done }
            return items.isEmpty ? nil : Group(note: note, items: items)
        }
    }

    private var openCount: Int {
        store.notes.reduce(0) { $0 + store.loadActions(noteID: $1.id).filter { !$0.done }.count }
    }

    private var unscanned: [NoteMeta] {
        store.notes.filter { !store.hasActions(noteID: $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { app.openNote(id: group.note.id) } label: {
                                    HStack(spacing: 6) {
                                        Text(group.note.title)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                ForEach(group.items) { item in
                                    itemRow(noteID: group.note.id, item: item)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarTitleLabel(text: openCount > 0 ? "Action items · \(openCount) open" : "Action items")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Show done", isOn: $showCompleted)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { scan() } label: {
                    // Text always, not just the icon: a lone hourglass or
                    // sparkle tells nobody what the button does.
                    if scanning {
                        Label(scanProgress, systemImage: "hourglass")
                    } else {
                        Label("Scan meetings", systemImage: "sparkles")
                    }
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.large)
                .disabled(scanning || unscanned.isEmpty)
                .help(unscanned.isEmpty ? "All meetings scanned. New meetings are added automatically." : "Find action items in meetings not yet analyzed")
            }
        }
    }

    private func itemRow(noteID: UUID, item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                store.setActionDone(noteID: noteID, actionID: item.id, done: !item.done)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.done ? Theme.record : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 13.5))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if let owner = item.owner, !owner.isEmpty {
                    Text(owner)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No action items yet")
                .font(.system(size: 15, weight: .semibold, design: .serif))
            Text(store.notes.isEmpty
                 ? "Load sample meetings to see how this works, or record a few."
                 : (unscanned.isEmpty
                    ? "New meetings get their action items pulled out automatically."
                    : "Scan your meetings to pull out every task and commitment."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                if !unscanned.isEmpty {
                    Button { scan() } label: {
                        Label(scanning ? scanProgress : "Scan \(unscanned.count) meeting\(unscanned.count == 1 ? "" : "s")", systemImage: "sparkles")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(scanning)
                }
                if !DemoData.isLoaded {
                    Button { DemoData.load(into: store) } label: {
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

    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let todo = unscanned
            for (index, note) in todo.enumerated() {
                scanProgress = "Scanning \(index + 1) of \(todo.count)"
                await recorder.extractActions(noteID: note.id)
            }
            scanning = false
            scanProgress = ""
        }
    }
}
