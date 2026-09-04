import SwiftUI
import AppKit
import AVFoundation

// Settings (Cmd+,): native controls, custom structure. One calm page of
// floating cards, every behavior explained in place.
struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .padding(.top, 18)
                    .padding(.bottom, 4)

                BehaviorCard()
                IntelligenceCard()
                CalendarCard()
                PermissionsCard()
                DataCard()

                Color.clear.frame(height: 16)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.windowBG)
        .frame(width: 620, height: 640)
    }
}

// Shared card scaffold: icon, title, one-line explainer, controls.
struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    let explainer: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(explainer)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Behavior

struct BehaviorCard: View {
    @EnvironmentObject var app: AppState
    @AppStorage("autoSummary") private var autoSummary = true
    @AppStorage("autoTitle") private var autoTitle = true

    var body: some View {
        SettingsCard(
            icon: "slider.horizontal.3",
            title: "Behavior",
            explainer: "How Earshot acts around your meetings. Opt+M starts a note from anywhere."
        ) {
            SettingsRow(title: "Floating controls", subtitle: "The small lozenge at the bottom of your screen.") {
                Toggle("", isOn: $app.hudVisible).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Summarize automatically", subtitle: "Write the summary the moment a recording stops.") {
                Toggle("", isOn: $autoSummary).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Name notes automatically", subtitle: "Titles appear a minute or two in. Your own edits always win.") {
                Toggle("", isOn: $autoTitle).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

// MARK: - Intelligence

struct IntelligenceCard: View {
    @EnvironmentObject var agent: AgentBridge
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        SettingsCard(
            icon: "brain",
            title: "Intelligence",
            explainer: "Summaries, titles, and questions run through an agent already on this Mac. No Earshot server, no API keys; transcripts are passed as plain text."
        ) {
            SettingsRow(title: "Agent", subtitle: "Found: \(agent.availability.summaryLine)") {
                Picker("", selection: $agent.preference) {
                    ForEach(AgentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            if agent.preference == .ollama || agent.availability.ollamaModel != nil {
                Divider().opacity(0.4)
                SettingsRow(title: "Ollama model") {
                    TextField("qwen3:4b", text: $agent.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
            }
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Button(isTesting ? "Testing" : "Test agent") { runTest() }
                    .buttonStyle(.glass)
                    .disabled(isTesting)
                Button("Refresh detection") { Task { await agent.detect() } }
                    .buttonStyle(.glass)
                if let testResult {
                    Text(testResult)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            do {
                let reply = try await agent.run(prompt: "Reply with exactly: ready")
                testResult = "Replied: \(reply.prefix(60))"
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

// MARK: - Calendar

struct CalendarCard: View {
    @EnvironmentObject var calendar: CalendarManager

    var body: some View {
        SettingsCard(
            icon: "calendar",
            title: "Calendar",
            explainer: "Shows today's meetings on Home so you can start a pre-titled note with one click. Read-only, on this Mac; nothing syncs anywhere."
        ) {
            SettingsRow(title: "Show upcoming meetings on Home") {
                Toggle("", isOn: $calendar.showUpcoming).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Access", subtitle: statusText) {
                switch calendar.status {
                case .notDetermined:
                    Button("Connect calendar") { calendar.connect() }
                        .buttonStyle(.glassProminent)
                case .denied:
                    Button("Open settings") { calendar.openSystemSettings() }
                        .buttonStyle(.glass)
                case .authorized:
                    Label("On", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.record)
                }
            }
        }
    }

    private var statusText: String {
        switch calendar.status {
        case .notDetermined: return "Not connected yet."
        case .denied: return "Turned off in System Settings."
        case .authorized: return "Connected to the calendars on this Mac."
        }
    }
}

// MARK: - Permissions

struct PermissionsCard: View {
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsCard(
            icon: "lock.shield",
            title: "Permissions",
            explainer: "Earshot records only when you press Record, shows a visible state the whole time, and keeps everything on this Mac."
        ) {
            row("Microphone", "Hears your side of the meeting.", granted: micGranted, anchor: "Privacy_Microphone")
            Divider().opacity(0.4)
            row("System Audio Recording", "Hears the other side of your call, without a bot. Asked on your first recording.", granted: nil, anchor: "Privacy_AudioCapture")
            Divider().opacity(0.4)
            row("Screen Recording", "Only for the capture button. Asked on your first capture.", granted: nil, anchor: "Privacy_ScreenCapture")
        }
        .onReceive(timer) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private func row(_ name: String, _ detail: String, granted: Bool?, anchor: String) -> some View {
        SettingsRow(title: name, subtitle: detail) {
            HStack(spacing: 8) {
                if granted == true {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.record)
                }
                Button("Open settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Data

struct DataCard: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        SettingsCard(
            icon: "folder",
            title: "Your data",
            explainer: "Each note is a folder of plain files: meta.json, transcript.jsonl, note.md, summary.md, chat.jsonl, and assets for captures. Grep them, sync them, back them up."
        ) {
            SettingsRow(title: "Notes folder", subtitle: store.baseDir.path) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.baseDir])
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}
