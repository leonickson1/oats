import SwiftUI
import AppKit

// First-run explainer: what Earshot does, what it needs, and how the user
// wants it to behave. Every switch here is a real setting.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var agent: AgentBridge

    @AppStorage("autoSummary") private var autoSummary = true
    @AppStorage("autoTitle") private var autoTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Earshot")
                    .font(.system(size: 22, weight: .bold))
                Text("Meeting notes that never leave your Mac. Here is how it works and what it needs.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            explainer(
                symbol: "record.circle",
                title: "Recording without a bot",
                body: "Press Record (or Opt+M). Earshot hears your mic and the audio of your call directly on this Mac, so nothing joins the meeting. macOS will ask once for Microphone and once for System Audio Recording; both are required to hear each side."
            )

            explainer(
                symbol: "brain",
                title: "Your AI, your keys",
                body: agent.availability.summaryLine == "No local agent found"
                    ? "Summaries and questions run through an agent already installed on your Mac. None was found yet; install Claude Code or Ollama and Earshot picks it up. Transcripts still work without one."
                    : "Summaries and questions run through what you already have: \(agent.availability.summaryLine). There is no Earshot server and no API key."
            ) {
                Toggle("Write the summary automatically when a recording stops", isOn: $autoSummary)
                Toggle("Name notes automatically from the conversation", isOn: $autoTitle)
            }

            explainer(
                symbol: "camera.viewfinder",
                title: "Capture slides and screens",
                body: "During a meeting, the capture button grabs any part of your screen into the note. Right-click a capture to read its text on-device; that text becomes part of the summary. macOS will ask once for Screen Recording the first time."
            )

            explainer(
                symbol: "folder",
                title: "Files you own",
                body: "Every note is a folder of plain files: the transcript, your notes, the summary, and captures. No database, no cloud, no export step."
            )

            HStack {
                Spacer()
                Button("Start taking notes") { app.finishOnboarding() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func explainer(symbol: String, title: String, body text: String, @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
                    .font(.system(size: 12.5))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
