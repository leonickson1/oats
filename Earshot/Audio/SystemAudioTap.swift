import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// Captures everything the Mac is playing (the other side of your call) using
// Core Audio process taps (macOS 14.2+). No bot joins the meeting; audio is
// read straight from the endpoint. Triggers the one-time
// "System Audio Recording" permission prompt.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "earshot.system-tap")
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    func start() throws {
        guard !isRunning else { return }

        // 1. A global tap: mix of all processes' output.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Earshot system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr else { throw SystemAudioTapError.tapCreation(err) }
        tapID = newTapID

        // 2. Read the tap's stream format.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw SystemAudioTapError.format(err)
        }
        tapFormat = format

        // 3. Wrap the tap in a private aggregate device so we can run an IO proc on it.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earshot tap device",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard err == noErr else {
            cleanup()
            throw SystemAudioTapError.aggregate(err)
        }
        aggregateID = newAggregateID

        // 4. Pull buffers.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(bufferList: inInputData)
        }
        guard err == noErr else {
            cleanup()
            throw SystemAudioTapError.ioProc(err)
        }
        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            cleanup()
            throw SystemAudioTapError.start(err)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        cleanup()
        isRunning = false
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
    }

    private func handle(bufferList: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat else { return }
        let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = ablPointer.first else { return }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames

        let dst = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (i, src) in ablPointer.enumerated() where i < dst.count {
            guard let srcData = src.mData, let dstData = dst[i].mData else { continue }
            let count = Int(min(src.mDataByteSize, dst[i].mDataByteSize))
            memcpy(dstData, srcData, count)
        }

        onBuffer?(pcm)
        onLevel?(MicCapture.rms(pcm))
    }
}

enum SystemAudioTapError: LocalizedError {
    case tapCreation(OSStatus)
    case format(OSStatus)
    case aggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreation(let s): return "Could not create the system audio tap (\(s)). Check the System Audio Recording permission in System Settings > Privacy & Security."
        case .format(let s): return "Could not read the tap audio format (\(s))."
        case .aggregate(let s): return "Could not create the capture device (\(s))."
        case .ioProc(let s): return "Could not attach the audio reader (\(s))."
        case .start(let s): return "Could not start system audio capture (\(s))."
        }
    }
}
