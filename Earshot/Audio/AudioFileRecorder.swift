import Foundation
import AVFoundation

// Saves the whole meeting to disk so it can be replayed later. Each session writes
// the raw mic and system-audio streams to CAF files; on stop both are mixed down to
// a single mono audio.m4a in the note folder. If the note already had audio (a
// resumed recording), that audio is kept and the new session is appended after it.
//
// Not @MainActor: appendMic/appendSystem are called from the audio render threads.
// Every file touch funnels through one serial queue, so the mic thread and the
// system-tap queue never write an AVAudioFile at the same time.
final class AudioFileRecorder {
    private let queue = DispatchQueue(label: "earshot.audio-writer")
    private let dir: URL
    private let micURL: URL
    private let sysURL: URL
    private var micFile: AVAudioFile?
    private var sysFile: AVAudioFile?

    init(dir: URL) {
        self.dir = dir
        micURL = dir.appendingPathComponent("mic.caf")
        sysURL = dir.appendingPathComponent("sys.caf")
        // Start each session from clean raw files; any prior audio.m4a is kept and
        // prepended during the mix.
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: sysURL)
    }

    static func audioURL(in dir: URL) -> URL { dir.appendingPathComponent("audio.m4a") }

    // MARK: - Realtime appends (audio threads)

    func appendMic(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.deepCopy() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.micFile == nil {
                    self.micFile = try AVAudioFile(forWriting: self.micURL, settings: copy.format.settings)
                }
                try self.micFile?.write(from: copy)
            } catch { DebugLog.log("audio mic write failed: \(error)") }
        }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.deepCopy() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.sysFile == nil {
                    self.sysFile = try AVAudioFile(forWriting: self.sysURL, settings: copy.format.settings)
                }
                try self.sysFile?.write(from: copy)
            } catch { DebugLog.log("audio sys write failed: \(error)") }
        }
    }

    // MARK: - Finish

    // Closes the raw files and mixes them (plus any prior audio) into audio.m4a.
    // Blocking; call from a background task after capture has fully stopped.
    func finishAndMix() {
        queue.sync {
            self.micFile = nil   // releasing the AVAudioFile flushes and closes it
            self.sysFile = nil
        }
        mixToFinal()
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: sysURL)
    }

    private func mixToFinal() {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else { return }
        let finalURL = Self.audioURL(in: dir)
        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSys = FileManager.default.fileExists(atPath: sysURL.path)
        guard hasMic || hasSys else { return }   // nothing was captured this session

        // If the note already had audio, move it aside and prepend it to the new mix.
        var priorReader: ChannelReader?
        let priorTmp = dir.appendingPathComponent("audio-prev.m4a")
        try? FileManager.default.removeItem(at: priorTmp)
        if FileManager.default.fileExists(atPath: finalURL.path),
           (try? FileManager.default.moveItem(at: finalURL, to: priorTmp)) != nil {
            priorReader = ChannelReader(url: priorTmp, target: target)
        }

        let micReader = hasMic ? ChannelReader(url: micURL, target: target) : nil
        let sysReader = hasSys ? ChannelReader(url: sysURL, target: target) : nil

        let tmp = dir.appendingPathComponent("audio-tmp.m4a")
        try? FileManager.default.removeItem(at: tmp)

        // writeMix owns the output file; it is released when the call returns, so the
        // encoder has flushed before we move the file into place.
        guard writeMix(to: tmp, target: target, prior: priorReader, mic: micReader, sys: sysReader) else {
            // Could not write; put the prior audio back so nothing is lost.
            if FileManager.default.fileExists(atPath: priorTmp.path) {
                try? FileManager.default.moveItem(at: priorTmp, to: finalURL)
            }
            return
        }
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: tmp, to: finalURL)
        try? FileManager.default.removeItem(at: priorTmp)
    }

    private func writeMix(to tmp: URL, target: AVAudioFormat, prior: ChannelReader?, mic: ChannelReader?, sys: ChannelReader?) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let outFile = try? AVAudioFile(forWriting: tmp, settings: settings) else { return false }
        let procFormat = outFile.processingFormat
        let chunk: AVAudioFrameCount = 48_000   // ~1s per iteration, bounded memory

        // 1. Prior audio first, copied straight through.
        if let prior {
            while let s = prior.next(target: target, frames: chunk) {
                writeChunk(s, to: outFile, format: procFormat)
            }
        }
        // 2. This session: mic + system summed sample for sample.
        while true {
            let a = mic?.next(target: target, frames: chunk)
            let b = sys?.next(target: target, frames: chunk)
            if a == nil, b == nil { break }
            let av = a ?? []
            let bv = b ?? []
            let n = max(av.count, bv.count)
            if n == 0 { continue }
            var mixed = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let m = i < av.count ? av[i] : 0
                let s = i < bv.count ? bv[i] : 0
                var v = m + s
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                mixed[i] = v
            }
            writeChunk(mixed, to: outFile, format: procFormat)
        }
        return true
    }

    private func writeChunk(_ samples: [Float], to file: AVAudioFile, format: AVAudioFormat) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)
        }
        try? file.write(from: buf)
    }
}

// Reads one audio file and converts it to a mono target format in bounded chunks.
// One AVAudioConverter is kept for the whole file so sample-rate conversion tails
// are handled correctly across chunk boundaries.
private final class ChannelReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private(set) var finished = false

    init?(url: URL, target: AVAudioFormat) {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        guard let c = AVAudioConverter(from: f.processingFormat, to: target) else { return nil }
        file = f
        converter = c
    }

    // Returns up to `frames` target-rate mono samples, or nil once fully drained.
    func next(target: AVAudioFormat, frames: AVAudioFrameCount) -> [Float]? {
        if finished { return nil }
        var spins = 0
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else {
                finished = true
                return nil
            }
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { [file] packetCount, inStatus in
                let cap = max(1, packetCount)
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else {
                    inStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try file.read(into: inBuf, frameCount: cap)
                } catch {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }
            if status == .error {
                finished = true
                return nil
            }
            let count = Int(outBuf.frameLength)
            if count > 0 {
                if status == .endOfStream { finished = true }
                guard let ch = outBuf.floatChannelData else { return [] }
                return Array(UnsafeBufferPointer(start: ch[0], count: count))
            }
            if status == .endOfStream {
                finished = true
                return nil
            }
            // Produced nothing but not yet at end; guard against an infinite spin.
            spins += 1
            if spins > 8 {
                finished = true
                return nil
            }
        }
    }
}

extension AVAudioPCMBuffer {
    // Format-agnostic copy so a transient render buffer survives a thread hop.
    func deepCopy() -> AVAudioPCMBuffer? {
        let frames = frameLength
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frames)) else { return nil }
        copy.frameLength = frames
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let bytes = Int(min(src[i].mDataByteSize, dst[i].mDataByteSize))
            memcpy(d, s, bytes)
        }
        return copy
    }
}
