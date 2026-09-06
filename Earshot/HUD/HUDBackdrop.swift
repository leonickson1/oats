import AppKit
import ScreenCaptureKit

// Tells the HUD how bright the screen is directly behind it, so the lozenge can
// adapt the way native glass does: dark pill with light ink over dark content,
// light pill with dark ink over a white page. We sample a tiny strip of the
// display under the panel (our own window excluded) and average its luminance.
// Uses the screen recording permission the app already holds for captures; with
// no permission it stays in the dark look, which was the old behavior.
//
// Robustness matters more than elegance here: if this stalls, every glyph in
// the HUD goes invisible over white. So a stuck ScreenCaptureKit call gets a
// hard timeout, a watchdog revives the loop if a capture hangs anyway, and
// results are generation-gated so a stale task can never overwrite fresh state.
@MainActor
final class HUDBackdrop: ObservableObject {
    @Published private(set) var overLight = false

    private weak var panel: NSPanel?
    private var timer: Timer?
    private var filter: SCContentFilter?
    private var displayFrame: CGRect = .zero   // Cocoa coordinates of the filtered display
    private var sampling = false
    private var samplingSince: Date?
    private var generation = 0   // bumped when a stuck task is abandoned

    func start(panel: NSPanel) {
        self.panel = panel
        let timer = Timer(timeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in AppState.shared.backdrop.sampleSoon() }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in AppState.shared.backdrop.sampleSoon() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                AppState.shared.backdrop.filter = nil
                AppState.shared.backdrop.sampleSoon()
            }
        }
        sampleSoon()
    }

    private let debug = ProcessInfo.processInfo.environment["EARSHOT_HUD_DEBUG"] == "1"

    func sampleSoon() {
        guard let panel, panel.isVisible else {
            if debug { fputs("backdrop: skip visible=\(panel?.isVisible ?? false)" + "\n", stderr) }
            return
        }
        if sampling {
            // Watchdog: a capture that has been "in flight" this long is hung
            // inside ScreenCaptureKit. Abandon it (its results are ignored via
            // the generation) and take over, otherwise adaptation would stay
            // dead for the rest of the session.
            if let since = samplingSince, Date().timeIntervalSince(since) > 8 {
                if debug { fputs("backdrop: watchdog reviving stuck sample" + "\n", stderr) }
                generation += 1
                sampling = false
                filter = nil
            } else {
                if debug { fputs("backdrop: skip sampling in flight" + "\n", stderr) }
                return
            }
        }
        guard CGPreflightScreenCaptureAccess() else {
            if debug { fputs("backdrop: no screen permission" + "\n", stderr) }
            return
        }
        sampling = true
        samplingSince = Date()
        let gen = generation
        let frame = panel.frame
        let windowID = CGWindowID(panel.windowNumber)
        Task { @MainActor in
            defer { if gen == generation { sampling = false } }
            do {
                // The filter captures one display. If the panel has moved to a
                // different monitor since it was built, rebuild it there,
                // otherwise we would keep sampling the old screen.
                if filter != nil, !displayFrame.intersects(frame) { filter = nil }
                if filter == nil {
                    let built = try await Self.withTimeout(seconds: 6) {
                        try await Self.buildFilter(around: frame, excluding: windowID)
                    }
                    guard gen == generation else { return }
                    guard let built else {
                        if debug { fputs("backdrop: no display for filter" + "\n", stderr) }
                        return
                    }
                    filter = built.filter
                    displayFrame = built.displayFrame
                }
                guard let filter else { return }
                let luminance = try await Self.withTimeout(seconds: 5) {
                    try await Self.measure(frame: frame, filter: filter, displayFrame: self.displayFrame)
                }
                guard gen == generation, let luminance else { return }
                apply(luminance: luminance)
            } catch {
                if debug { fputs("backdrop: sample failed \(error)" + "\n", stderr) }
                if gen == generation { filter = nil }   // stale reference; rebuilt next tick
            }
        }
    }

    private func apply(luminance: Double) {
        if debug { fputs("backdrop: luminance \(luminance) overLight=\(overLight)" + "\n", stderr) }
        // Hysteresis so a busy mid-grey background never makes the pill flicker.
        if luminance > 0.62, !overLight {
            overLight = true
        } else if luminance < 0.48, overLight {
            overLight = false
        }
        // Vibrancy blending happens at the panel's AppKit layer, so the panel
        // appearance must flip along with the SwiftUI scheme; otherwise dark
        // ink gets vibrancy-brightened back to white over a white page.
        let wanted: NSAppearance.Name = overLight ? .aqua : .darkAqua
        if panel?.appearance?.name != wanted {
            panel?.appearance = NSAppearance(named: wanted)
        }
    }

    // ScreenCaptureKit calls can hang indefinitely; every await goes through
    // this race so one bad call costs seconds, not the session.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    private struct BuiltFilter: Sendable {
        let filter: SCContentFilter
        let displayFrame: CGRect
    }

    private static func buildFilter(around frame: CGRect, excluding windowID: CGWindowID) async throws -> BuiltFilter? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == screenNumber })
        else { return nil }
        let ours = content.windows.filter { $0.windowID == windowID }
        return BuiltFilter(filter: SCContentFilter(display: display, excludingWindows: ours), displayFrame: screen.frame)
    }

    private static func measure(frame: CGRect, filter: SCContentFilter, displayFrame: CGRect) async throws -> Double? {
        // The panel frame, translated into the display's top-left-origin space.
        let local = CGRect(
            x: frame.minX - displayFrame.minX,
            y: displayFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        // Screenshot sourceRect is unreliable (it can silently fall back to the
        // full display), so grab the whole display tiny and average only the
        // strip under the panel ourselves.
        let configuration = SCStreamConfiguration()
        configuration.width = 160
        configuration.height = max(1, Int((160.0 * displayFrame.height / max(displayFrame.width, 1)).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        let region = CGRect(
            x: local.minX / max(displayFrame.width, 1),
            y: local.minY / max(displayFrame.height, 1),
            width: local.width / max(displayFrame.width, 1),
            height: local.height / max(displayFrame.height, 1)
        )
        return meanLuminance(of: image, region: region)
    }

    // Average luminance inside `region`, given normalized with top-left origin
    // (matching the raster's row order after drawing into a bitmap context).
    private static func meanLuminance(of image: CGImage, region: CGRect) -> Double? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x0 = max(0, min(width - 1, Int(region.minX * CGFloat(width))))
        let y0 = max(0, min(height - 1, Int(region.minY * CGFloat(height))))
        let x1 = max(x0 + 1, min(width, Int((region.maxX * CGFloat(width)).rounded(.up))))
        let y1 = max(y0 + 1, min(height, Int((region.maxY * CGFloat(height)).rounded(.up))))

        var total = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
                total += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            }
        }
        return total / Double((x1 - x0) * (y1 - y0))
    }
}
