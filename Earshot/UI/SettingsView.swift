import SwiftUI
import AppKit
import AVFoundation

// Native Settings window (Cmd+,). Every behavior Earshot has is visible and
// explained here, in the user's own control.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntelligenceSettings()
                .tabItem { Label("Intelligence", systemImage: "brain") }
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            DataSettings()
                .tabItem { Label("Your data", systemImage: "folder") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var app: AppState
    @AppStorage("autoSummary") private var autoSummary = true
    @AppStorage("autoTitle") private var autoTitle = true

    var body: some View {
        Form {
            Section {
                Toggle("Show floating controls", isOn: $app.hudVisible)
                Toggle("Write the summary automatically when a recording stops", isOn: $autoSummary)
                Toggle("Name notes automatically from the conversation", isOn: $autoTitle)
            } footer: {
                Text("Auto-naming looks at the transcript a minute or two in and titles the note. Editing the title yourself always wins; Earshot never overwrites it after that.")
            }
            Section("Shortcuts") {
                LabeledContent("New meeting note (works anywhere)", value: "Opt M")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct IntelligenceSettings: View {
    @EnvironmentObject var agent: AgentBridge
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: $agent.preference) {
                    ForEach(AgentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                LabeledContent("Detected", value: agent.availability.summaryLine)
                if agent.preference == .ollama || agent.availability.ollamaModel != nil {
                    TextField("Ollama model", text: $agent.ollamaModel, prompt: Text("qwen3:4b"))
                }
                HStack {
                    Button(isTesting ? "Testing" : "Test agent") { runTest() }
                        .disabled(isTesting)
                    Button("Refresh detection") { Task { await agent.detect() } }
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } footer: {
                Text("Summaries, titles, and questions run through an agent already on this Mac: Claude Code, Codex, or Ollama. Earshot has no server and no API keys. Transcripts are passed as plain text; nothing else is shared.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            do {
                let reply = try await agent.run(prompt: "Reply with exactly: ready")
                testResult = "Agent replied: \(reply.prefix(60))"
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

struct PermissionsSettings: View {
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permissionRow(
                    name: "Microphone",
                    detail: "Hears your side of the meeting.",
                    granted: micGranted,
                    anchor: "Privacy_Microphone"
                )
                permissionRow(
                    name: "System Audio Recording",
                    detail: "Hears the other side of your call, without a bot. Asked on your first recording.",
                    granted: nil,
                    anchor: "Privacy_AudioCapture"
                )
                permissionRow(
                    name: "Screen Recording",
                    detail: "Only for the capture button (slides, shared screens). Asked on your first capture.",
                    granted: nil,
                    anchor: "Privacy_ScreenCapture"
                )
            } footer: {
                Text("Earshot records only when you press Record, shows a visible state the whole time, and keeps everything on this Mac.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onReceive(timer) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private func permissionRow(name: String, detail: String, granted: Bool?, anchor: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let granted {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(granted ? Color.green : Color.secondary)
                }
                Button("Open settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } label: {
            Text(name)
            Text(detail)
        }
    }
}

struct DataSettings: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Notes folder") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.baseDir])
                    }
                }
                Text(store.baseDir.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } footer: {
                Text("Each note is a folder of plain files: meta.json, transcript.jsonl, note.md, summary.md, chat.jsonl, and an assets folder for captures. Grep them, sync them, back them up. Deleting a note deletes its folder.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
