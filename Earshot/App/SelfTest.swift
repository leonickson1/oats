import Foundation
import AVFoundation

// Debug hook: EARSHOT_SELFTEST_AUDIO=/path/to/audio launches the app, runs the
// file through the exact transcription pipeline used for meetings, writes the
// result next to the input as <name>.transcript.txt, and quits. Lets CI and
// agents verify the pipeline without a microphone.
enum SelfTest {
    static func runIfRequested() {
        if let secs = ProcessInfo.processInfo.environment["EARSHOT_SELFTEST_MIC"] {
            runMic(seconds: Double(secs) ?? 6)
            return
        }
        runFile()
    }

    // Records from the real mic for N seconds through the meeting pipeline and
    // writes /tmp/earshot-mic.txt with peak level, buffer count, and transcript.
    static func runMic(seconds: Double) {
        Task { @MainActor in
            let outURL = URL(fileURLWithPath: "/tmp/earshot-mic.txt")
            var log: [String] = []
            var lines: [String] = []
            var bufferCount = 0
            var peak: Float = 0
            do {
                let granted = await MicCapture.requestPermission()
                log.append("mic permission granted: \(granted)")
                guard granted else { throw NSError(domain: "selftest", code: 1) }

                let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
                try await TranscriberPipeline.ensureAssets(locale: locale)
                let pipe = TranscriberPipeline(label: "mic")
                pipe.onResult = { text, isFinal in
                    log.append("result final=\(isFinal): \(text)")
                    if isFinal { lines.append(text) }
                }
                try await pipe.start(locale: locale)

                let mic = MicCapture()
                mic.onBuffer = { buffer in
                    bufferCount += 1
                    pipe.feed(buffer)
                }
                mic.onLevel = { level in peak = max(peak, level) }
                try mic.start(echoCancellation: false)
                log.append("mic engine started, format: \(String(describing: pipe))")

                try? await Task.sleep(for: .seconds(seconds))
                mic.stop()
                await pipe.finishAndWait()
                try? await Task.sleep(for: .milliseconds(500))
                log.append("buffers: \(bufferCount), peak level: \(peak)")
                log.append("TRANSCRIPT: \(lines.joined(separator: " "))")
                try log.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                log.append("ERROR: \(String(reflecting: error))")
                try? log.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }

    static func runFile() {
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
