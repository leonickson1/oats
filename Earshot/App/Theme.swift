import SwiftUI

// Earshot design system. Flat, warm, quiet.
// Rules: no gradients, no pulsing indicators, no grey icon circles, sentence case.
enum Theme {
    // Surfaces
    static let windowBG = Color(red: 0.984, green: 0.980, blue: 0.969)      // warm near-white
    static let sidebarBG = Color(red: 0.960, green: 0.951, blue: 0.933)     // cream
    static let card = Color.white
    static let hairline = Color(red: 0.906, green: 0.890, blue: 0.859)
    static let hover = Color(red: 0.945, green: 0.937, blue: 0.918)
    static let selection = Color(red: 0.922, green: 0.910, blue: 0.886)

    // Ink
    static let ink = Color(red: 0.114, green: 0.110, blue: 0.102)
    static let secondary = Color(red: 0.443, green: 0.427, blue: 0.400)
    static let tertiary = Color(red: 0.639, green: 0.620, blue: 0.588)

    // Accents (small, purposeful)
    static let recordGreen = Color(red: 0.114, green: 0.639, blue: 0.373)
    static let destructive = Color(red: 0.769, green: 0.263, blue: 0.216)

    // HUD (dark floating pills)
    static let hudBG = Color(red: 0.075, green: 0.078, blue: 0.090)
    static let hudSubtle = Color(red: 0.180, green: 0.184, blue: 0.200)
    static let hudText = Color.white
}

// MARK: - Reusable components

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .background(prominent ? Theme.ink : Theme.card)
            .overlay(
                Capsule().strokeBorder(prominent ? Color.clear : Theme.hairline, lineWidth: 1)
            )
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct HairlineCard: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func hairlineCard(radius: CGFloat = 14) -> some View { modifier(HairlineCard(radius: radius)) }
}

// Live waveform bars driven by real mic levels. Static when silent, never fake-animated.
struct WaveformBars: View {
    var levels: [Float]
    var barColor: Color = .white
    var barCount: Int = 11

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                let level = levelFor(index: i)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 2.5, height: max(3, CGFloat(level) * 16))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func levelFor(index: Int) -> Float {
        guard !levels.isEmpty else { return 0.1 }
        let recent = Array(levels.suffix(barCount))
        if index < barCount - recent.count { return 0.12 }
        let v = recent[index - (barCount - recent.count)]
        return min(1, max(0.12, v * 6))
    }
}
