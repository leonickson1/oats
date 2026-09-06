import AppKit
import ScreenCaptureKit

// Tells the HUD how bright the screen is directly behind it, so the lozenge can
// adapt the way native glass does: dark pill with light ink over dark content,
// light pill with dark ink over a white page. We sample a tiny strip of the
// display under the panel (our own window excluded) and average its luminance.
// Uses the screen recording permission the app already holds for captures; with
// no permission it stays in the dark look, which was the old behavior.
@MainActor
final class HUDBackdrop: ObservableObject {
    @Published private(set) var overLight = false

    private weak var panel: NSPanel?
    private var timer: Timer?
    private var filter: SCContentFilter?
    private var displayFrame: CGRect = .zero   // Cocoa coordinates of the filtered display
    private var sampling = false

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
        guard let panel, panel.isVisible, !sampling else {
            if debug { fputs("backdrop: skip visible=\(panel?.isVisible ?? false) sampling=\(sampling)" + "\n", stderr) }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            if debug { fputs("backdrop: no screen permission" + "\n", stderr) }
            return
        }
        sampling = true
        let frame = panel.frame
        let windowID = CGWindowID(panel.windowNumber)
        Task { @MainActor in
            defer { sampling = false }
            do {
                if filter == nil { try await rebuildFilter(around: frame, excluding: windowID) }
                guard let filter else {
                    if debug { fputs("backdrop: no filter" + "\n", stderr) }
                    return
                }
                try await sample(frame: frame, filter: filter)
            } catch {
                if debug { fputs("backdrop: sample failed \(error)" + "\n", stderr) }
                filter = nil   // stale display or window reference; rebuilt next tick
            }
        }
    }

    private func rebuildFilter(around frame: CGRect, excluding windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == screenNumber })
        else { return }
        let ours = content.windows.filter { $0.windowID == windowID }
        filter = SCContentFilter(display: display, excludingWindows: ours)
        displayFrame = screen.frame
    }

    private func sample(frame: CGRect, filter: SCContentFilter) async throws {
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
        guard let luminance = Self.meanLuminance(of: image, region: region) else { return }
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
