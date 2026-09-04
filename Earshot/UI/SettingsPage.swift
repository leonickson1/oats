import SwiftUI
import AppKit

struct SettingsPage: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var agent: AgentBridge
    @EnvironmentObject var store: NoteStore
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 48)

                settingsCard(title: "Intelligence") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Summaries and questions run through an agent already on this Mac. Nothing is sent to an Earshot server, because there is none.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondary)

                        Picker("Agent", selection: $agent.preference) {
                            ForEach(AgentKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)

                        HStack(spacing: 8) {
                            Text("Detected: \(agent.availability.summaryLine)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                            Button("Refresh") { Task { await agent.detect() } }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                        }

                        if agent.preference == .ollama || agent.availability.ollamaModel != nil {
                            TextField("Ollama model (for example qwen3:4b)", text: $agent.ollamaModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }

                        HStack(spacing: 10) {
                            Button(isTesting ? "Testing" : "Test agent") { runTest() }
                                .buttonStyle(PillButtonStyle())
                                .disabled(isTesting)
                            if let testResult {
                                Text(testResult)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                settingsCard(title: "Your data") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Notes are plain files: meta.json, transcript.jsonl, note.md, summary.md. Grep them, sync them, back them up. They are yours.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondary)
                        HStack(spacing: 10) {
                            Text(store.baseDir.path)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([store.baseDir])
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                }

                settingsCard(title: "Controls") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show floating controls", isOn: $app.hudVisible)
                            .toggleStyle(.switch)
                            .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 5) {
                            shortcutRow(keys: "Opt M", label: "New meeting note")
                            shortcutRow(keys: "Opt .", label: "Toggle dictation")
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
            content()
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .hairlineCard()
    }

    private func shortcutRow(keys: String, label: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.sidebarBG)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            do {
                let reply = try await agent.run(prompt: "Reply with exactly: ready")
                testResult = "Agent replied: \(reply.prefix(80))"
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
