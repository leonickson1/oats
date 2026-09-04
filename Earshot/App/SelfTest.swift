import Foundation
import AVFoundation

// Debug hook: EARSHOT_SELFTEST_AUDIO=/path/to/audio launches the app, runs the
// file through the exact transcription pipeline used for meetings, writes the
// result next to the input as <name>.transcript.txt, and quits. Lets CI and
// agents verify the pipeline without a microphone.
enum SelfTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["EARSHOT_SELFTEST_AUDIO"] else { return }
        Task { @MainActor in
            let outURL = URL(fileURLWithPath: path + ".transcript.txt")
            var lines: [String] = []
            var step = "start"
            do {
                step = "locale"
                let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
                step = "assets (locale \(locale.identifier))"
                try await TranscriberPipeline.ensureAssets(locale: locale)
                step = "pipeline"
                let pipe = TranscriberPipeline(label: "selftest")
                pipe.onResult = { text, isFinal in
                    if isFinal { lines.append(text) }
                }
                step = "pipe.start"
                try await pipe.start(locale: locale)

                step = "open audio file"
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                step = "read audio chunks"
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                    try file.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    pipe.feed(buffer)
                }
                await pipe.finishAndWait()
                // Final results land on the main actor; give them a beat.
                try? await Task.sleep(for: .milliseconds(500))
                try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                try? "SELFTEST ERROR at \(step): \(String(reflecting: error))".write(to: outURL, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }
}
