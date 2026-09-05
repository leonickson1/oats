import SwiftUI
import AppKit

// Earshot uses Apple-native materials and semantic colors so light and dark
// mode both work for free. Rules: no gradients, no fake pulsing, sentence case.
enum Theme {
    // Semantic, adaptive.
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let card = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let windowBG = Color(nsColor: .windowBackgroundColor)

    // One small accent for recording state. Never decorative.
    static let record = Color(red: 0.157, green: 0.655, blue: 0.416)
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator.opacity(0.45), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func card(radius: CGFloat = 14) -> some View { modifier(CardBackground(radius: radius)) }
}

// Small metadata capsule (date, duration, status) under a note title.
struct MetaChip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

// A dashed pause/resume divider, like a seam in the transcript.
struct DashedMarker: View {
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Label(label, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize()
            line
        }
        .padding(.vertical, 3)
    }

    private var line: some View {
        Rectangle()
            .frame(height: 1)
            .foregroundStyle(.clear)
            .overlay(
                GeometryReader { geo in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0.5))
                        p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                }
            )
    }
}

// The Earshot mark: a listener dot with two hearing arcs. Drawn, not an SF symbol.
struct EarshotMark: View {
    var color: Color = .primary
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let cx = w * 0.22
            let cy = h / 2
            let dotR = h * 0.14
            Path { p in
                p.addEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
            }
            .fill(color)
            Path { p in
                p.addArc(center: CGPoint(x: cx, y: cy), radius: h * 0.34,
                         startAngle: .degrees(-42), endAngle: .degrees(42), clockwise: false)
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Path { p in
                p.addArc(center: CGPoint(x: cx, y: cy), radius: h * 0.58,
                         startAngle: .degrees(-38), endAngle: .degrees(38), clockwise: false)
            }
            .stroke(color.opacity(0.65), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .aspectRatio(1.15, contentMode: .fit)
    }
}

// A centered record indicator: a filled dot inside a thin ring, the standard
// record affordance. Built as a ZStack so the dot is always dead-centered in its
// frame regardless of the surrounding layout.
struct RecordGlyph: View {
    var color: Color = Theme.record
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.9), lineWidth: max(1, size * 0.1))
            Circle()
                .fill(color)
                .frame(width: size * 0.46, height: size * 0.46)
        }
        .frame(width: size, height: size)
    }
}

// Live waveform bars driven by real audio levels. Flat when silent, never fake.
struct WaveformBars: View {
    var levels: [Float]
    var barColor: Color = .primary
    var barCount: Int = 11
    var maxHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 2.5, height: max(3, CGFloat(levelFor(index: i)) * maxHeight))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func levelFor(index: Int) -> Float {
        guard !levels.isEmpty else { return 0.12 }
        let recent = Array(levels.suffix(barCount))
        if index < barCount - recent.count { return 0.12 }
        let v = recent[index - (barCount - recent.count)]
        return min(1, max(0.12, v * 6))
    }
}
