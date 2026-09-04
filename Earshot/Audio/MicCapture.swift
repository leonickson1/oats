import Foundation
import AVFoundation

// Microphone capture via AVAudioEngine. Voice processing gives echo cancellation,
// so system audio playing through speakers is not re-transcribed as "Me".
final class MicCapture {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(echoCancellation: Bool = true) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        if echoCancellation {
            // Best effort; falls back to plain capture if voice processing is unavailable.
            try? input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "Earshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"]) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
            self?.onLevel?(MicCapture.rms(buffer))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isRunning = false
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var i = 0
        while i < n {
            let v = data[i]
            sum += v * v
            i += 8   // stride; metering does not need every sample
        }
        return sqrtf(sum / Float(max(1, n / 8)))
    }
}
