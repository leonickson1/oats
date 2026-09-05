import SwiftUI
import Combine

// The transcription models Oats can use, all LOCAL, nothing in the cloud.
// Apple's built-in model streams live and needs only a small language pack; the
// others are downloadable engines (figures are approximate, for comparison).
enum TranscriptionEngine: String {
    case apple, whisper, parakeet
}

struct TranscriptionModel: Identifiable {
    let id: String
    let name: String
    let engine: TranscriptionEngine
    let live: Bool          // true = streams during the meeting, false = after
    let speed: Int          // 1...5
    let accuracy: Int       // 1...5
    let sizeMB: Int?        // nil = built in, no download
    let languages: String
    let note: String
    let available: Bool     // engine wired and runnable today
}

enum TranscriptionCatalog {
    // Ordered best-default first. Local only.
    static let all: [TranscriptionModel] = [
        TranscriptionModel(id: "apple", name: "Apple Speech", engine: .apple, live: true,
                           speed: 5, accuracy: 4, sizeMB: nil, languages: "Multilingual",
                           note: "Built in to macOS. Streams live on the Neural Engine.", available: true),
        TranscriptionModel(id: "parakeet-v3", name: "Parakeet v3", engine: .parakeet, live: false,
                           speed: 5, accuracy: 4, sizeMB: 620, languages: "25 languages",
                           note: "NVIDIA Parakeet on the Neural Engine, extremely fast. One combined transcript, no speaker split.", available: true),
        TranscriptionModel(id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", engine: .whisper, live: false,
                           speed: 4, accuracy: 5, sizeMB: 632, languages: "Multilingual",
                           note: "Near top accuracy, much faster than full Large. One combined transcript, no speaker split.", available: true),
        TranscriptionModel(id: "whisper-large-v3", name: "Whisper Large v3", engine: .whisper, live: false,
                           speed: 2, accuracy: 5, sizeMB: 1550, languages: "Multilingual",
                           note: "Highest accuracy. Heavier and slower. One combined transcript, no speaker split.", available: true),
        TranscriptionModel(id: "whisper-small", name: "Whisper Small", engine: .whisper, live: false,
                           speed: 4, accuracy: 3, sizeMB: 483, languages: "Multilingual",
                           note: "Light and quick, good for fast notes. One combined transcript.", available: true),
        TranscriptionModel(id: "whisper-tiny", name: "Whisper Tiny", engine: .whisper, live: false,
                           speed: 5, accuracy: 2, sizeMB: 78, languages: "Multilingual",
                           note: "Fastest, lowest accuracy. One combined transcript.", available: true),
    ]

    static func model(id: String) -> TranscriptionModel {
        all.first { $0.id == id } ?? all[0]
    }

    static func color(_ engine: TranscriptionEngine) -> Color {
        switch engine {
        case .apple: return .primary
        case .parakeet: return Color(red: 0.30, green: 0.55, blue: 0.45)
        case .whisper: return Color(red: 0.42, green: 0.45, blue: 0.72)
        }
    }

    static func symbol(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .apple: return "apple.logo"
        case .parakeet: return "bird.fill"
        case .whisper: return "waveform"
        }
    }
}

// Live status of Apple's on-device speech language pack (the only local engine
// wired today). Shared by onboarding and Settings.
@MainActor
final class SpeechAssets: ObservableObject {
    @Published private(set) var locale: Locale?
    @Published private(set) var ready = false
    @Published private(set) var checking = true
    @Published private(set) var downloading = false
    @Published private(set) var error: String?

    var langName: String {
        locale.flatMap { Locale.current.localizedString(forLanguageCode: $0.language.languageCode?.identifier ?? "en") } ?? "your language"
    }

    var detail: String {
        if checking { return "Checking the language pack…" }
        if downloading { return "Downloading the \(langName) language pack…" }
        if ready { return "Apple's \(langName) model is ready, fully on this Mac." }
        if let error { return error }
        return "Apple's \(langName) speech model. A one-time language-pack download."
    }

    func check() async {
        let loc = await TranscriberPipeline.supportedLocale(matching: .current) ?? Locale(identifier: "en-US")
        locale = loc
        ready = await TranscriberPipeline.assetsInstalled(locale: loc)
        checking = false
    }

    func download() {
        guard let loc = locale else { return }
        downloading = true
        error = nil
        Task {
            do {
                try await TranscriberPipeline.ensureAssets(locale: loc)
                ready = true
            } catch {
                self.error = "Could not download the language pack. Check your connection and try again."
            }
            downloading = false
        }
    }
}

// Live download state for the Whisper engines. Each model downloads once into
// Application Support and then runs locally. Shared by onboarding and Settings.
@MainActor
final class WhisperModels: ObservableObject {
    @Published private(set) var downloaded: Set<String> = []
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published var error: String?

    func refresh() {
        var found: Set<String> = []
        for model in TranscriptionCatalog.all {
            switch model.engine {
            case .whisper: if WhisperEngine.isDownloaded(id: model.id) { found.insert(model.id) }
            case .parakeet: if ParakeetEngine.isDownloaded(id: model.id) { found.insert(model.id) }
            case .apple: break
            }
        }
        downloaded = found
    }

    func isDownloading(_ id: String) -> Bool { downloading.contains(id) }
    // Fraction 0...1, or a negative value meaning "in progress, no percentage".
    func fraction(_ id: String) -> Double { progress[id] ?? 0 }

    func download(_ id: String) {
        guard !downloading.contains(id), !downloaded.contains(id) else { return }
        let engine = TranscriptionCatalog.model(id: id).engine
        downloading.insert(id)
        progress[id] = engine == .parakeet ? -1 : 0   // Parakeet has no fractional progress
        error = nil
        Task {
            do {
                switch engine {
                case .whisper:
                    try await WhisperEngine.download(id: id) { p in
                        Task { @MainActor in self.progress[id] = p }
                    }
                case .parakeet:
                    try await ParakeetEngine.download()
                case .apple:
                    break
                }
                downloaded.insert(id)
            } catch {
                self.error = "Could not download \(TranscriptionCatalog.model(id: id).name). \(error.localizedDescription)"
            }
            downloading.remove(id)
            progress[id] = nil
        }
    }
}

// Small 5-pip meter for speed / accuracy figures.
struct MeterBars: View {
    let value: Int
    var tint: Color = .primary
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(i < value ? tint : Color.secondary.opacity(0.22))
                    .frame(width: 11, height: 4)
            }
        }
    }
}

// The Superwhisper-style model list: name, live/after, speed + accuracy, size,
// and an action (use / download / coming soon). Local only.
struct TranscriptionModelList: View {
    @ObservedObject var speech: SpeechAssets
    @ObservedObject var whisper: WhisperModels
    @Binding var selectedID: String

    var body: some View {
        VStack(spacing: 8) {
            ForEach(TranscriptionCatalog.all) { model in
                row(model)
            }
            if let error = whisper.error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { whisper.refresh() }
    }

    private func row(_ model: TranscriptionModel) -> some View {
        let isApple = model.engine == .apple
        let isDownloadable = model.engine == .whisper || model.engine == .parakeet
        let installed = isApple ? speech.ready : (isDownloadable ? whisper.downloaded.contains(model.id) : false)
        let selected = selectedID == model.id
        let selectable = model.available && (installed || isApple)

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TranscriptionCatalog.color(model.engine).opacity(0.14))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: TranscriptionCatalog.symbol(model.engine))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TranscriptionCatalog.color(model.engine))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    Image(systemName: model.live ? "waveform" : "clock.arrow.circlepath")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .help(model.live ? "Streams live during the meeting" : "Transcribes after the meeting")
                }
                Text(isApple ? speech.detail : model.note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                meter("Speed", model.speed)
                meter("Accuracy", model.accuracy)
            }
            .fixedSize()

            action(model, isApple: isApple, isDownloadable: isDownloadable, installed: installed, selected: selected)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(selected ? Theme.record.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? Theme.record.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .opacity(model.available ? 1 : 0.72)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { if selectable { selectedID = model.id } }
    }

    private func meter(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)
            MeterBars(value: value, tint: Theme.record)
        }
    }

    @ViewBuilder
    private func action(_ model: TranscriptionModel, isApple: Bool, isDownloadable: Bool, installed: Bool, selected: Bool) -> some View {
        if isApple {
            if speech.checking || speech.downloading {
                ProgressView().controlSize(.small)
            } else if installed {
                useState(model, selected: selected)
            } else {
                Button("Download") { speech.download() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        } else if isDownloadable {
            if whisper.isDownloading(model.id) {
                if whisper.fraction(model.id) < 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Downloading")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: whisper.fraction(model.id))
                            .controlSize(.small)
                            .frame(width: 72)
                        Text("\(Int(whisper.fraction(model.id) * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else if installed {
                useState(model, selected: selected)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    if let mb = model.sizeMB {
                        Text(sizeLabel(mb))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Button("Download") { whisper.download(model.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                if let mb = model.sizeMB {
                    Text(sizeLabel(mb))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("Soon")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .help("This local engine is coming to Oats")
            }
        }
    }

    @ViewBuilder
    private func useState(_ model: TranscriptionModel, selected: Bool) -> some View {
        if selected {
            Label("In use", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 18))
                .foregroundStyle(Theme.record)
        } else {
            Button("Use") { selectedID = model.id }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func sizeLabel(_ mb: Int) -> String {
        mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB"
    }
}
