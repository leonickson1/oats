import SwiftUI
import AppKit

// First run: a short, paged welcome. Four minimal pages with a graphic each,
// native Continue buttons, and a real "connect your AI" step at the end where
// people pick (or download) the local model Oats will use.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var agent: AgentBridge

    @State private var page = 0
    private let pageCount = 5

    // The only local transcription engine wired today is Apple's; this tracks its
    // language-pack download so the last page can require it before entry.
    @StateObject private var speech = SpeechAssets()
    @StateObject private var perms = Permissions()
    @AppStorage("transcriptionModelID") private var transcriptionModelID = "apple"

    // The app cannot work without a way to turn speech into text AND a model to
    // reason over it. Both must be real before "Get started" unlocks.
    private var hasReasoning: Bool {
        agent.appleAvailable
            || agent.availability.claudePath != nil
            || agent.availability.codexPath != nil
            || !agent.ollamaModels.isEmpty
    }
    private var canFinish: Bool { perms.mic == .granted && speech.ready && hasReasoning }

    private var blockingReason: String? {
        if perms.mic != .granted { return "Allow microphone access to continue." }
        if speech.checking { return "Checking the transcription model…" }
        if speech.downloading { return "Downloading the transcription model…" }
        if !speech.ready { return "Download the transcription model to continue." }
        if !hasReasoning { return "Choose or download a model to continue." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView {
                    currentPage
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                        .id(page)
                        .transition(Motion.contentSwap)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 640, height: 600)
        .background(Theme.windowBG)
        .animation(Motion.standard, value: page)
        .task {
            await agent.detect()
            await speech.check()
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case 0: welcomePage
        case 1: capturePage
        case 2: permissionsPage
        case 3: understandPage
        default:
            AIPage(agent: agent, speech: speech, transcriptionModelID: $transcriptionModelID)
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        pageScaffold {
            EarshotTileLogoView(size: 108)
                .overlay(
                    RoundedRectangle(cornerRadius: 108 * 0.22, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            title("Welcome to Oats")
            subtitle("Meeting notes that never leave your Mac. Oats listens, transcribes, and thinks on this machine. No bot joins your call, no account, no cloud.")
        }
    }

    private var capturePage: some View {
        pageScaffold {
            iconHero("record.circle")
            title("Record without a bot")
            subtitle("Press Record, or Opt+M. Oats captures your microphone and your call's audio directly on this Mac, so nothing joins the meeting. macOS will ask once for Microphone and once for System Audio.")
            VStack(spacing: 10) {
                Toggle("Write the summary automatically when a recording stops", isOn: autoSummaryBinding)
                Toggle("Name notes automatically from the conversation", isOn: autoTitleBinding)
            }
            .toggleStyle(.switch)
            .font(.system(size: 12.5))
            .frame(maxWidth: 420)
            .padding(.top, 4)
        }
    }

    private var permissionsPage: some View {
        pageScaffold {
            iconHero("lock.shield")
            title("Grant a few permissions")
            subtitle("Oats asks for everything up front so recording just works. It only listens when you press Record, and nothing leaves this Mac.")
            PermissionsChecklist(perms: perms)
                .frame(maxWidth: 460)
                .padding(.top, 4)
        }
    }

    private var understandPage: some View {
        pageScaffold {
            iconHero("point.3.connected.trianglepath.dotted")
            title("Understand everything")
            subtitle("Every meeting feeds the same local memory.")
            VStack(spacing: 12) {
                featureRow("point.3.connected.trianglepath.dotted", "Knowledge graph", "People, projects and topics, linked across all your meetings.")
                featureRow("checklist", "Action items", "Every commitment pulled out and tracked in one place.")
                featureRow("folder", "Spaces", "Group meetings by class or client, each with its own chat.")
                featureRow("sparkle.magnifyingglass", "Ask anything", "Chat across your meetings, answered by your local AI.")
            }
            .frame(maxWidth: 440)
            .padding(.top, 6)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if page > 0 {
                Button("Back") { withAnimation(Motion.standard) { page -= 1 } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
            Spacer()
            if page == pageCount - 1, let blockingReason {
                Text(blockingReason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.primary : Color.secondary.opacity(0.28))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            Spacer()
            Button(page == pageCount - 1 ? "Get started" : "Continue") {
                if page == pageCount - 1 { app.finishOnboarding() }
                else { withAnimation(Motion.standard) { page += 1 } }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(page == pageCount - 1 && !canFinish)
        }
        .padding(20)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func pageScaffold<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 28)
        .multilineTextAlignment(.center)
    }

    // Just the icon, no circle behind it.
    private func iconHero(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 54, weight: .regular))
            .foregroundStyle(Theme.record)
            .frame(height: 108)
    }

    private func title(_ text: String) -> some View {
        // System sans (SF Pro), no serif in onboarding.
        Text(text).font(.system(size: 25, weight: .bold))
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 440)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func featureRow(_ symbol: String, _ name: String, _ detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.record)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // Real settings, edited right here.
    private var autoSummaryBinding: Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: "autoSummary") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "autoSummary") })
    }
    private var autoTitleBinding: Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: "autoTitle") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "autoTitle") })
    }
}

// The "connect your AI" step: shows every local option, lets people choose one,
// and can download an Ollama model right here with a progress bar.
private struct AIPage: View {
    @ObservedObject var agent: AgentBridge
    @ObservedObject var speech: SpeechAssets
    @StateObject private var whisper = WhisperModels()
    @Binding var transcriptionModelID: String

    @State private var pulling = false
    @State private var pullProgress: Double = 0
    @State private var pullStatus = ""
    @State private var pullError: String?

    private let recommended = "llama3.2"

    private var nothingAvailable: Bool {
        !agent.appleAvailable
            && agent.availability.claudePath == nil
            && agent.availability.codexPath == nil
            && agent.ollamaModels.isEmpty
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("Bring your own AI")
                    .font(.system(size: 23, weight: .bold))
                Text("Nothing goes to the cloud. Speech becomes text with Apple's on-device model, and a second model writes summaries, the graph, and chat.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Transcription  ·  local only")
                TranscriptionModelList(speech: speech, whisper: whisper, selectedID: $transcriptionModelID)

                sectionLabel("Summaries and chat")
                providerRow(.apple,
                            name: "Apple Intelligence",
                            detail: agent.appleAvailable ? "Built in. Nothing to download." : (agent.appleReason ?? "Not available"),
                            enabled: agent.appleAvailable)
                providerRow(.claudeCode,
                            name: "Claude Code",
                            detail: agent.availability.claudePath != nil ? "Found on this Mac." : "Not found. Install the claude CLI.",
                            enabled: agent.availability.claudePath != nil)
                providerRow(.codex,
                            name: "Codex",
                            detail: agent.availability.codexPath != nil ? "Found on this Mac." : "Not found. Install the codex CLI.",
                            enabled: agent.availability.codexPath != nil)
                providerRow(.ollama,
                            name: "Ollama",
                            detail: agent.ollamaModels.isEmpty ? "No local models yet. Download one below." : "\(agent.ollamaModels.count) model\(agent.ollamaModels.count == 1 ? "" : "s") ready.",
                            enabled: !agent.ollamaModels.isEmpty)
                downloadCard
            }
            .frame(maxWidth: 552)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func providerRow(_ kind: AgentKind, name: String, detail: String, enabled: Bool) -> some View {
        let selected = agent.preference == kind
        return Button {
            guard enabled else { return }
            agent.preference = kind
        } label: {
            HStack(spacing: 12) {
                ProviderMark(provider: Provider.from(kind), size: 20, color: enabled ? .primary : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.record)
                } else if enabled {
                    Image(systemName: "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(selected ? Theme.record.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? Theme.record.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .opacity(enabled ? 1 : 0.7)
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.record)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download a model")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(pulling ? (pullStatus.isEmpty ? "Starting…" : pullStatus.capitalized) : "Get \(recommended) (about 2 GB) through Ollama, no terminal needed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if !pulling {
                    Button("Download") { downloadRecommended() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                }
            }
            if pulling {
                if pullProgress >= 0 {
                    ProgressView(value: pullProgress)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let pullError {
                Text(pullError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func downloadRecommended() {
        pulling = true
        pullError = nil
        pullProgress = -1
        pullStatus = ""
        Task {
            do {
                try await agent.pullOllama(model: recommended) { progress, status in
                    pullProgress = progress
                    pullStatus = status
                }
                agent.preference = .ollama
                if agent.ollamaModel.isEmpty { agent.ollamaModel = recommended }
            } catch {
                pullError = error.localizedDescription
            }
            pulling = false
        }
    }
}
