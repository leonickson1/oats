import Foundation
import AVFoundation
import Combine

// Plays back a saved meeting recording. Drives the transcript's play head so a
// tap on any line can seek straight to that moment.
@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var scrubbing = false

    var isLoaded: Bool { player != nil }

    func load(_ url: URL) {
        if loadedURL == url, player != nil { return }
        teardown()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
        loadedURL = url
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        // Restart from the top if we were parked at the end.
        if currentTime >= duration - 0.05 { player.currentTime = 0; currentTime = 0 }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    // Jump to a transcript line and start playing from there.
    func playFrom(_ t: TimeInterval) {
        guard player != nil else { return }
        seek(to: t)
        play()
    }

    func seek(to t: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, t), max(0, duration - 0.05))
        player.currentTime = clamped
        currentTime = clamped
    }

    // Slider drag: pause the play head follow while the user drags.
    func beginScrub() { scrubbing = true; stopTicker() }
    func endScrub(to t: TimeInterval) {
        scrubbing = false
        seek(to: t)
        if isPlaying { startTicker() }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player, !scrubbing else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            // Finished.
            isPlaying = false
            stopTicker()
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    func teardown() {
        stopTicker()
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
