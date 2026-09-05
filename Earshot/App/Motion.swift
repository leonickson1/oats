import SwiftUI
import AppKit

// Motion, following Apple's Human Interface Guidelines: it should be purposeful
// and brief, and it must ease off when the user asks for less. When "Reduce
// Motion" is on (System Settings > Accessibility > Display), spatial springs
// become quick cross-fades so nothing slides, scales, or bounces.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Everyday transitions: expand/collapse, selection, a view appearing.
    static var standard: Animation {
        reduce ? .easeInOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    // Small, fast state changes: highlights, toggles, focus.
    static var quick: Animation {
        .easeInOut(duration: reduce ? 0.12 : 0.2)
    }

    // Swapping one piece of content for another. A cross-fade always reads as
    // calm, and it is the recommended fallback when motion is reduced.
    static var contentSwap: AnyTransition { .opacity }
}
