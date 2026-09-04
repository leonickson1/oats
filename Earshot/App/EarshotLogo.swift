import SwiftUI
import AppKit

// The Earshot mark, authored as SVG and rendered natively via NSImage (macOS
// renders SVG). Concept: the letter E built from three audio-level bars, so it
// reads as both the initial and a sound meter. Bold, flat, scales cleanly.
enum EarshotLogo {
    // Plain mark in the given color, transparent background (for inline/HUD use).
    static func svg(stroke: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="none">
          <g stroke="\(stroke)" stroke-width="12" stroke-linecap="round">
            <line x1="32" y1="26" x2="32" y2="74"/>
            <line x1="32" y1="32" x2="74" y2="32"/>
            <line x1="32" y1="50" x2="60" y2="50"/>
            <line x1="32" y1="68" x2="78" y2="68"/>
          </g>
        </svg>
        """
    }

    // Tiled version for the app icon: cream mark on an ink rounded square.
    static func tileSVG() -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="none">
          <rect width="100" height="100" rx="22" fill="#111113"/>
          <g stroke="#F5F3EF" stroke-width="12" stroke-linecap="round">
            <line x1="32" y1="26" x2="32" y2="74"/>
            <line x1="32" y1="32" x2="74" y2="32"/>
            <line x1="32" y1="50" x2="60" y2="50"/>
            <line x1="32" y1="68" x2="78" y2="68"/>
          </g>
        </svg>
        """
    }

    static func image(color: NSColor, size: CGFloat) -> NSImage? {
        let hex = color.usingColorSpace(.sRGB).map { c -> String in
            String(format: "#%02X%02X%02X",
                   Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        } ?? "#FFFFFF"
        guard let data = svg(stroke: hex).data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }
}

// SwiftUI wrapper that recolors with the environment and redraws on color scheme.
struct EarshotLogoView: View {
    var color: Color = .primary
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = EarshotLogo.image(color: NSColor(color), size: size) {
            Image(nsImage: nsImage)
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // Fallback if SVG rendering is unavailable.
            EarshotMark(color: color)
                .frame(width: size, height: size)
        }
    }
}
