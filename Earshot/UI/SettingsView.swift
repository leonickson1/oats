import SwiftUI
import AppKit
import AVFoundation
import Carbon.HIToolbox

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
                TranscriptionCard()
                IntelligenceCard()
                AskCard()
                CalendarCard()
                PermissionsCard()
                SampleDataCard()
                UpdatesCard()
                DataCard()
                ResetCard()

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

// MARK: - Transcription

struct TranscriptionCard: View {
    @StateObject private var speech = SpeechAssets()
    @StateObject private var whisper = WhisperModels()
    @AppStorage("transcriptionModelID") private var transcriptionModelID = "apple"

    var body: some View {
        SettingsCard(
            icon: "waveform",
            title: "Transcription",
            explainer: "The model that turns speech into text, entirely on this Mac. Apple's model streams live during the meeting; Whisper models download once and re-transcribe the recording afterward for higher accuracy."
        ) {
            TranscriptionModelList(speech: speech, whisper: whisper, selectedID: $transcriptionModelID)
        }
        .task { await speech.check() }
    }
}

// MARK: - Behavior

struct BehaviorCard: View {
    @EnvironmentObject var app: AppState
    @AppStorage("autoSummary") private var autoSummary = true
    @AppStorage("autoTitle") private var autoTitle = true
    @AppStorage("autoEnrich") private var autoEnrich = true

    var body: some View {
        SettingsCard(
            icon: "slider.horizontal.3",
            title: "Behavior",
            explainer: "How Oats acts around your meetings. Opt+M starts a note from anywhere."
        ) {
            SettingsRow(title: "Floating controls", subtitle: "The small lozenge at the bottom of your screen.") {
                Toggle("", isOn: $app.hudVisible).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Offer notes when a call starts", subtitle: "Zoom, Meet, FaceTime, WhatsApp and browser calls raise a small card on the lozenge.") {
                Toggle("", isOn: Binding(
                    get: { app.meetings.enabled },
                    set: { app.meetings.enabled = $0 }
                )).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Summarize automatically", subtitle: "Write the summary the moment a recording stops.") {
                Toggle("", isOn: $autoSummary).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Name notes automatically", subtitle: "Titles appear a minute or two in. Your own edits always win.") {
                Toggle("", isOn: $autoTitle).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Update action items and knowledge graph", subtitle: "Pull out tasks and update the graph automatically after each meeting. Off, the Scan and Analyze buttons still work by hand.") {
                Toggle("", isOn: $autoEnrich).toggleStyle(.switch).labelsHidden()
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
            explainer: "Summaries, titles, and questions run through an AI already on this Mac. No Oats server, no API keys; transcripts are passed as plain text."
        ) {
            // What is installed, each with a live connection state.
            connectionRow("Claude Code", detail: "claude", connected: agent.availability.claudePath != nil)
            Divider().opacity(0.4)
            connectionRow("Codex", detail: "codex", connected: agent.availability.codexPath != nil)
            Divider().opacity(0.4)
            connectionRow("Ollama", detail: agent.ollamaModels.isEmpty ? "not running" : "\(agent.ollamaModels.count) models", connected: !agent.ollamaModels.isEmpty)
            Divider().opacity(0.4)
            connectionRow("Apple Intelligence", detail: agent.appleAvailable ? "built in" : (agent.appleReason ?? "unavailable"), connected: agent.appleAvailable)

            Divider().opacity(0.4)
            SettingsRow(title: "Use", subtitle: "Which one Oats asks. Auto picks the first available.") {
                Picker("", selection: $agent.preference) {
                    ForEach(AgentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            // Once Ollama is connected, choose from every model it has.
            if !agent.ollamaModels.isEmpty && (agent.preference == .ollama || agent.preference == .auto) {
                Divider().opacity(0.4)
                SettingsRow(title: "Ollama model", subtitle: "Pick which local model answers.") {
                    Picker("", selection: $agent.ollamaModel) {
                        ForEach(agent.ollamaModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Button(isTesting ? "Testing" : "Test agent") { runTest() }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(isTesting)
                Button("Refresh") { Task { await agent.detect() } }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
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

    private func connectionRow(_ name: String, detail: String, connected: Bool) -> some View {
        SettingsRow(title: name, subtitle: detail) {
            Label(connected ? "Connected" : "Not found", systemImage: connected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(connected ? Theme.record : Color.secondary)
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

// MARK: - Ask popup

struct AskCard: View {
    @AppStorage("askSuggestion1") private var suggestion1 = "Summarize my last meeting"
    @AppStorage("askSuggestion2") private var suggestion2 = "List today's action items"

    var body: some View {
        SettingsCard(
            icon: "sparkles",
            title: "Ask popup",
            explainer: "Summon it anywhere with a global shortcut. These two quick prompts sit under the bar; make them whatever you ask most. Leave one blank to hide it."
        ) {
            SettingsRow(title: "Summon shortcut", subtitle: "The global key combo that opens Ask from anywhere.") {
                ShortcutRecorder()
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Quick prompt 1") {
                TextField("Summarize my last meeting", text: $suggestion1)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Quick prompt 2") {
                TextField("List today's action items", text: $suggestion2)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
        }
    }
}

// Records a global shortcut for summoning Ask. Click to arm, then press the combo.
// Stores the Carbon keycode + modifiers (and a display label) and live-reloads the
// registered hotkey. Requires at least one modifier so a bare key can't be captured.
struct ShortcutRecorder: View {
    @AppStorage("askHotkeyKeyCode") private var keyCode = kVK_Space
    @AppStorage("askHotkeyModifiers") private var modifiers = optionKey
    @AppStorage("askHotkeyKeyLabel") private var keyLabel = "Space"

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private var isDefault: Bool { keyCode == HotkeyManager.defaultAskKeyCode && modifiers == HotkeyManager.defaultAskModifiers }

    var body: some View {
        HStack(spacing: 8) {
            if let hint, recording {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            if !recording && !isDefault {
                Button("Reset") { reset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : HotkeyManager.modifierSymbols(modifiers) + keyLabel)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(recording ? Theme.record : nil)
            .help("Click, then press the keys you want")
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else {
                hint = "Add a modifier (⌥, ⌘, ⌃)"
                return nil
            }
            keyCode = Int(event.keyCode)
            modifiers = mods
            keyLabel = Self.label(for: event)
            HotkeyManager.shared.reloadAskHotkey()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    private func reset() {
        keyCode = HotkeyManager.defaultAskKeyCode
        modifiers = HotkeyManager.defaultAskModifiers
        keyLabel = "Space"
        HotkeyManager.shared.reloadAskHotkey()
    }

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_ANSI_KeypadEnter: return "Enter"
        default:
            let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
            return chars.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Key \(event.keyCode)" : chars
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
                        .buttonBorderShape(.capsule)
                case .denied:
                    Button("Open settings") { calendar.openSystemSettings() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
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
            explainer: "Oats records only when you press Record, shows a visible state the whole time, and keeps everything on this Mac."
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
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Data

struct SampleDataCard: View {
    @EnvironmentObject var store: NoteStore
    @State private var loaded = DemoData.isLoaded

    var body: some View {
        SettingsCard(
            icon: "sparkles",
            title: "Sample meetings",
            explainer: "Load 12 connected demo meetings (people, projects, customers) so you can try the knowledge graph, action items and search. Then hit Analyze / Scan on those screens to generate them."
        ) {
            SettingsRow(title: loaded ? "Sample meetings loaded" : "Try Oats with example data",
                        subtitle: loaded ? "Remove them any time" : "12 meetings added to Home") {
                if loaded {
                    Button("Remove samples", role: .destructive) {
                        DemoData.remove(from: store)
                        loaded = false
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                } else {
                    Button("Load samples") {
                        DemoData.load(into: store)
                        loaded = true
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
        }
    }
}

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
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Danger zone

// A deliberately alarming card that erases everything. Red header, a plain
// "don't use this" warning, a destructive button gated behind a confirmation,
// and disabled while a recording is in progress so it can't nuke a live note.
struct ResetCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var recorder: MeetingRecorder
    @State private var confirming = false
    @State private var justReset = false

    private let danger = Color(red: 0.78, green: 0.19, blue: 0.13)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(danger)
                    .frame(width: 18)
                Text("Reset Oats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(danger)
            }
            Text("Danger: this permanently erases every note, transcript, recording, chat, space, action item and the whole knowledge graph. Your AI connections and settings stay. There is no undo. Don't use this unless you really mean it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label("Erase everything…", systemImage: "trash")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(danger)
                .disabled(recorder.isActive)

                if recorder.isActive {
                    Text("Stop the current recording first.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if justReset {
                    Label("Everything erased", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(danger.opacity(0.35), lineWidth: 1)
        )
        .confirmationDialog(
            "Erase everything in Oats?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Erase everything", role: .destructive) {
                app.resetAllData()
                justReset = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all notes, transcripts, recordings, chats, spaces, action items and the knowledge graph on this Mac. Your AI connections and settings are kept. This cannot be undone.")
        }
    }
}
