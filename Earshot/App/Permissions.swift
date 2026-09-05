import Foundation
import AVFoundation
import CoreGraphics
import AppKit

// One place for the macOS permissions Oats needs, so onboarding and the Home
// banner show the same live state. Microphone and screen recording are queryable;
// system audio has no status API, so we only learn it by probing (a throwaway tap)
// or on the first real recording.
@MainActor
final class Permissions: ObservableObject {
    enum Access: Equatable { case granted, denied, notDetermined }

    @Published private(set) var mic: Access = .notDetermined
    @Published private(set) var screen: Access = .notDetermined
    @Published private(set) var systemAudio: Access = .notDetermined
    @Published private(set) var probingSystemAudio = false

    private var timer: Timer?

    init() {
        refresh()
        // Catch grants made directly in System Settings while the app is open.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    // The microphone is the one permission Oats genuinely cannot work without.
    var needsAttention: Bool { mic != .granted }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
        // Preflight is true only once granted; false means "not yet or denied", so
        // only upgrade to granted here and never clobber a known .denied.
        if CGPreflightScreenCaptureAccess() {
            screen = .granted
        } else if screen == .granted {
            screen = .notDetermined
        }
    }

    func requestMic() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        }
    }

    func requestScreen() {
        // Prompts the first time; if already denied it returns false with no prompt.
        screen = CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    // Creating a process tap triggers the one-time System Audio Recording prompt.
    // We start and immediately stop a throwaway tap purely to ask for access.
    func requestSystemAudio() {
        guard !probingSystemAudio else { return }
        probingSystemAudio = true
        Task.detached { [weak self] in
            let tap = SystemAudioTap()
            var ok = false
            do { try tap.start(); ok = true; tap.stop() } catch { ok = false }
            await MainActor.run {
                self?.systemAudio = ok ? .granted : .denied
                self?.probingSystemAudio = false
            }
        }
    }

    func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
