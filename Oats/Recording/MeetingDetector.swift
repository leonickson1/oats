import Foundation
import CoreAudio
import AppKit

// Notices when a call starts on this Mac, the way Granola and Wispr do: Core
// Audio publishes one HAL object per process using audio, and each object says
// whether that process currently has a live input (microphone) stream. When a
// known call app or a browser opens the mic, we surface a quiet offer in the
// HUD. Nothing is recorded and no permission is involved; this is public
// hardware state, read locally.
@MainActor
final class MeetingDetector: ObservableObject {
    struct Detection: Equatable {
        let bundleID: String
        let appName: String
        let isBrowser: Bool
    }

    // The call currently on the mic that we want to offer notes for, nil when
    // quiet. Dismissing keeps it nil until that app releases the mic.
    @Published private(set) var current: Detection?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "detectCalls") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "detectCalls")
            if newValue { start() } else { stopTimer(); current = nil }
            objectWillChange.send()
        }
    }

    private var timer: Timer?
    private var dismissedBundleID: String?
    private var pendingBundleID: String?   // seen once; confirmed on the next tick

    // Dedicated call apps. FaceTime audio runs inside avconferenced.
    private static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "Cisco-Systems.Spark": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.avconferenced": "FaceTime",
        "com.skype.skype": "Skype",
        "com.hnc.Discord": "Discord",
        "com.tinyspeck.slackmacgap": "Slack",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.Telegram": "Telegram",
        "com.tdesktop.Telegram": "Telegram",
        "com.facebook.archon": "Messenger",
        "com.loom.desktop": "Loom",
    ]

    // Browsers cover Meet, in-browser Zoom/Teams, Huddles, and the rest.
    private static let browsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.microsoft.edgemac": "Edge",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    func start() {
        // QA hook: OATS_FAKE_CALL=WhatsApp renders the offer card without a
        // real call, so the HUD flow can be exercised and screenshotted.
        if let fake = ProcessInfo.processInfo.environment["OATS_FAKE_CALL"], !fake.isEmpty {
            current = Detection(bundleID: "fake.\(fake)", appName: fake, isBrowser: false)
            return
        }
        guard enabled, timer == nil else { return }
        // A light poll: each tick is a handful of tiny mach calls into
        // coreaudiod. Listeners exist, but per-process listener bookkeeping is
        // where detectors grow race conditions; two seconds of latency is fine
        // for "a call just started".
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in AppState.shared.meetings.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        pendingBundleID = nil
    }

    func dismiss() {
        dismissedBundleID = current?.bundleID
        current = nil
    }

    private func tick() {
        guard enabled else { return }
        // While Oats itself is recording, the lozenge is already busy; the
        // call's audio is being captured, so there is nothing to offer.
        if AppState.shared.recorder.isActive {
            current = nil
            pendingBundleID = nil
            return
        }
        let running = Self.processesRunningInput()

        // The mic went quiet for the dismissed app: forget the dismissal.
        if let dismissed = dismissedBundleID, !running.contains(dismissed) {
            dismissedBundleID = nil
        }

        // Pick the strongest candidate: a dedicated call app over a browser.
        var candidate: Detection?
        for id in running {
            if let name = Self.callApps[id] {
                candidate = Detection(bundleID: id, appName: name, isBrowser: false)
                break
            }
            if candidate == nil, let name = Self.browsers[id] {
                candidate = Detection(bundleID: id, appName: name, isBrowser: true)
            }
        }

        guard let candidate, candidate.bundleID != dismissedBundleID else {
            current = nil
            pendingBundleID = nil
            return
        }

        // Two consecutive ticks before offering, so a half-second mic blip
        // (a voice memo preview, a permission probe) never raises the card.
        if current?.bundleID == candidate.bundleID { return }
        if pendingBundleID == candidate.bundleID {
            pendingBundleID = nil
            current = candidate
        } else {
            pendingBundleID = candidate.bundleID
        }
    }

    // Exercised by the logic self-test: proves the HAL query path completes.
    nonisolated static func selfTestProbe() -> Set<String> {
        processesRunningInput()
    }

    // Bundle IDs of every other process that currently holds a live input stream.
    private nonisolated static func processesRunningInput() -> Set<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        var result: Set<String> = []
        for object in objects {
            guard processPID(object) != ourPID, isRunningInput(object),
                  let bundle = bundleID(object), !bundle.isEmpty else { continue }
            result.insert(bundle)
        }
        return result
    }

    private nonisolated static func processPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return pid
    }

    private nonisolated static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return false }
        return running == 1
    }

    private nonisolated static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard err == noErr else { return nil }
        return value as String?
    }
}
