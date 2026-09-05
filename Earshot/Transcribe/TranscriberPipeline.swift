import Foundation
import Speech
import AVFoundation

// One on-device transcription pipeline (Apple SpeechAnalyzer, macOS 26+).
// A meeting uses two of these: mic ("me") and system audio ("them").
final class TranscriberPipeline {
    let label: String

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var analyzerFormat: AVAudioFormat?

    // (text, isFinal) delivered on the main actor.
    var onResult: (@MainActor (String, Bool) -> Void)?

    init(label: String) {
        self.label = label
    }

    static func supportedLocale(matching locale: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
            ?? supported.first { $0.language.languageCode == locale.language.languageCode }
    }

    // Whether the on-device speech model for this locale is already installed
    // (no download needed). assetInstallationRequest returns nil when nothing is
    // left to install.
    static func assetsInstalled(locale: Locale) async -> Bool {
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe])
        return (request ?? nil) == nil
    }

    // Downloads the on-device model for the locale if needed.
    static func ensureAssets(locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        DebugLog.log("[\(label)] pipeline started, analyzerFormat sr=\(analyzerFormat?.sampleRate ?? -1)")

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = continuation

        resultsTask = Task { [weak self] in
            guard let transcriber = self?.transcriber else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    guard !text.isEmpty else { continue }
                    DebugLog.log("[\(self?.label ?? "?")] result final=\(isFinal): \(text.prefix(40))")
                    await MainActor.run { [weak self] in
                        self?.onResult?(text, isFinal)
                    }
                }
            } catch {
                DebugLog.log("[\(self?.label ?? "?")] results stream error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    private var fedCount = 0

    // Called from audio threads; conversion is cheap relative to capture cadence.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let inputBuilder, let analyzerFormat else { return }
        guard let converted = convert(buffer, to: analyzerFormat) else {
            if fedCount == 0 { DebugLog.log("[\(label)] convert returned nil") }
            return
        }
        fedCount += 1
        if fedCount == 1 || fedCount == 50 { DebugLog.log("[\(label)] fed buffer #\(fedCount)") }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    func finishAndWait() async {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        inputBuilder = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        converterSourceFormat = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
