import Foundation
import AVFoundation

// Microphone capture via AVAudioEngine. Captures the raw mic; echo cancellation
// via voice processing is avoided because it zeroes the input when the engine
// renders no output, which produced silent meetings.
final class MicCapture {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(echoCancellation: Bool = false) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        if echoCancellation {
            try? input.setVoiceProcessingEnabled(true)
        }

        // Touching mainMixerNode instantiates the output graph so the engine
        // actually runs its IO cycle and the input tap receives buffers.
        engine.mainMixerNode.outputVolume = 0

        let format = input.inputFormat(forBus: 0)
        DebugLog.log("MicCapture format sr=\(format.sampleRate) ch=\(format.channelCount)")
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Oats", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
            self?.onLevel?(MicCapture.rms(buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            DebugLog.log("MicCapture engine.start failed: \(error)")
            input.removeTap(onBus: 0)
            throw error
        }
        DebugLog.log("MicCapture engine started, running=\(engine.isRunning)")
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
