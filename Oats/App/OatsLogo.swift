import SwiftUI
import AppKit

// The mark: a small cluster of cells (three linked orbs, each a membrane with a
// nucleus). Reads as connected ideas, the knowledge graph in miniature. Rendered
// natively via NSImage (macOS renders SVG). Source: svgrepo "cell".
enum OatsLogo {
    // Cell membranes (outlines) and nuclei (centers), viewBox 0 0 1024 1024.
    private static let membranes = """
    <path d="M515.2 200c70.4-28.8 129.6-33.6 211.2-8 60.8 19.2 91.2 44.8 120 97.6 6.4 11.2 30.4 59.2 33.6 67.2 28.8 57.6 24 100.8-3.2 169.6-12.8 32-14.4 35.2-17.6 46.4-14.4 52.8-67.2 99.2-120 124.8-4.8 3.2-9.6 4.8-17.6 9.6-3.2 1.6-3.2 1.6-4.8 3.2-35.2 17.6-56 25.6-89.6 27.2-64 4.8-216-80-256-153.6-40-75.2-33.6-225.6 8-273.6 36.8-48 88-91.2 136-110.4z m11.2 30.4c-41.6 17.6-89.6 56-126.4 100.8-32 36.8-38.4 174.4-3.2 238.4 33.6 62.4 172.8 140.8 225.6 136 28.8-1.6 46.4-8 78.4-24 3.2-1.6 3.2-1.6 4.8-3.2 8-4.8 12.8-6.4 19.2-9.6 46.4-20.8 92.8-62.4 104-104 3.2-12.8 4.8-17.6 19.2-51.2 25.6-60.8 28.8-96 4.8-142.4-4.8-9.6-27.2-56-33.6-67.2-25.6-46.4-48-65.6-100.8-83.2-76.8-20.8-128-16-192 9.6z" fill="COLOR"/>
    <path d="M382.4 587.2l3.2 16c-9.6 1.6-20.8 4.8-32 9.6-22.4 9.6-49.6 30.4-70.4 56-17.6 20.8-20.8 94.4-1.6 129.6 17.6 33.6 96 76.8 124.8 75.2 16-1.6 25.6-4.8 43.2-12.8 1.6 0 1.6 0 3.2-1.6 4.8-1.6 8-3.2 9.6-4.8 25.6-11.2 51.2-33.6 57.6-56 1.6-8 3.2-9.6 9.6-27.2 9.6-22.4 12.8-35.2 11.2-51.2l16-1.6c1.6 19.2-1.6 33.6-12.8 59.2-6.4 17.6-8 19.2-9.6 25.6-8 28.8-36.8 54.4-65.6 67.2-3.2 1.6-4.8 3.2-9.6 4.8-1.6 0-1.6 0-3.2 1.6-19.2 9.6-30.4 14.4-49.6 14.4-35.2 3.2-118.4-43.2-139.2-83.2-22.4-40-17.6-121.6 3.2-148.8 22.4-27.2 49.6-49.6 76.8-59.2 12.8-8 24-11.2 35.2-12.8z" fill="COLOR"/>
    <path d="M185.6 144c24-9.6 44.8-11.2 72-3.2 20.8 6.4 32 16 41.6 33.6l11.2 22.4c9.6 20.8 8 35.2-1.6 59.2-3.2 11.2-4.8 12.8-4.8 16-4.8 17.6-24 35.2-41.6 43.2-1.6 0-3.2 1.6-6.4 3.2-1.6 0-1.6 0-1.6 1.6-12.8 6.4-19.2 8-30.4 9.6-22.4 1.6-75.2-27.2-88-52.8-14.4-25.6-11.2-76.8 3.2-94.4 12.8-17.6 28.8-32 46.4-38.4z m4.8 16c-12.8 4.8-28.8 17.6-41.6 33.6-9.6 11.2-11.2 56-1.6 76.8 11.2 19.2 56 44.8 73.6 43.2 9.6 0 14.4-3.2 25.6-8 1.6 0 1.6 0 1.6-1.6 3.2-1.6 4.8-1.6 6.4-3.2 14.4-6.4 30.4-20.8 33.6-32 1.6-4.8 1.6-6.4 6.4-17.6 8-19.2 9.6-30.4 1.6-44.8l-11.2-22.4c-8-14.4-14.4-20.8-32-25.6-24-8-41.6-8-62.4 1.6z" fill="COLOR"/>
    """
    private static func nuclei(_ color: String) -> String {
        """
        <path d="M612.8 464m-112 0a112 112 0 1 0 224 0 112 112 0 1 0-224 0Z" fill="\(color)"/>
        <path d="M404.8 736m-48 0a48 48 0 1 0 96 0 48 48 0 1 0-96 0Z" fill="\(color)"/>
        <path d="M228.8 232m-24 0a24 24 0 1 0 48 0 24 24 0 1 0-48 0Z" fill="\(color)"/>
        """
    }

    // Plain single-color mark (for inline/HUD use). Membranes and nuclei share
    // the tint, so each cell reads as a ring with a solid center.
    static func svg(stroke: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
        \(membranes.replacingOccurrences(of: "COLOR", with: stroke))
        \(nuclei(stroke))
        </svg>
        """
    }

    // Tiled version for the app icon: cream cells with warm nuclei, on ink.
    static func tileSVG() -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
        <rect width="1024" height="1024" rx="225" fill="#111113"/>
        \(membranes.replacingOccurrences(of: "COLOR", with: "#F5F3EF"))
        \(nuclei("#D2703F"))
        </svg>
        """
    }

    // The full app-icon mark: cream E on an ink rounded square.
    static func tileImage(size: CGFloat) -> NSImage? {
        guard let data = tileSVG().data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
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

    // A template (mask) version of the mark: drawn solid and flagged as a
    // template, so SwiftUI vibrancy tints it and flips it light/dark along with
    // the Liquid Glass behind it, exactly the way a standard SF Symbol does. Use
    // this on glass; the baked-color `image(color:)` cannot adapt.
    static func templateImage(size: CGFloat) -> NSImage? {
        guard let data = svg(stroke: "#000000").data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

// The full app-icon logo (ink tile + cream mark), for splash/onboarding use.
struct OatsTileLogoView: View {
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let nsImage = OatsLogo.tileImage(size: size) {
                Image(nsImage: nsImage).interpolation(.high).frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color(red: 0.067, green: 0.067, blue: 0.075))
                    .frame(width: size, height: size)
                    .overlay(OatsLogoView(color: Color(red: 0.96, green: 0.953, blue: 0.937), size: size * 0.52))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// SwiftUI wrapper that recolors with the environment and redraws on color scheme.
struct OatsLogoView: View {
    var color: Color = .primary
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = OatsLogo.image(color: NSColor(color), size: size) {
            Image(nsImage: nsImage)
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // Fallback if SVG rendering is unavailable.
            OatsMark(color: color)
                .frame(width: size, height: size)
        }
    }
}

// Vibrant variant for Liquid Glass: renders the mark as a template image so it
// takes the current foreground style and flips light/dark automatically with the
// material behind it. No baked color, so nothing to keep in sync with a sampler.
// Tint it (for a functional state) by applying `.foregroundStyle` at the call
// site; left alone it inherits the adaptive label color, like a glyph on glass.
struct OatsGlyphView: View {
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let nsImage = OatsLogo.templateImage(size: size) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .interpolation(.high)
                    .resizable()
            } else {
                OatsMark()
            }
        }
        .frame(width: size, height: size)
    }
}
