import SwiftUI

// A space's icon is an SF Symbol name (clean, monochrome, native). Older spaces
// may still hold an emoji; SpaceGlyph tells them apart so both keep rendering.
enum SpaceGlyph {
    static func isEmoji(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        if first.isASCII { return false }   // SF Symbol names are ASCII
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && first.value >= 0x1F000)
    }

    // A sensible starting icon for a brand-new space.
    static let defaultSymbol = "books.vertical.fill"
}

// Draws a space icon: an SF Symbol, or an emoji for legacy spaces.
struct SpaceIcon: View {
    let symbol: String
    var size: CGFloat = 15
    var color: Color = .secondary

    var body: some View {
        if SpaceGlyph.isEmoji(symbol) {
            Text(symbol)
                .font(.system(size: size))
        } else {
            Image(systemName: symbol.isEmpty ? SpaceGlyph.defaultSymbol : symbol)
                .font(.system(size: size))
                .foregroundStyle(color)
        }
    }
}

// The curated SF Symbols offered in the icon picker: study, work, projects, life.
enum SpaceSymbols {
    static let all: [String] = [
        "books.vertical.fill", "graduationcap.fill", "book.fill", "pencil.and.ruler.fill",
        "function", "atom", "backpack.fill", "text.book.closed.fill",
        "briefcase.fill", "building.2.fill", "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "dollarsign.circle.fill", "doc.text.fill", "banknote.fill", "calendar",
        "paperplane.fill", "lightbulb.fill", "target", "hammer.fill",
        "wrench.and.screwdriver.fill", "puzzlepiece.fill", "folder.fill", "pin.fill",
        "paintpalette.fill", "film.fill", "music.note", "camera.fill",
        "leaf.fill", "heart.fill", "flame.fill", "star.fill",
        "cup.and.saucer.fill", "airplane", "house.fill", "pawprint.fill",
        "cross.case.fill", "figure.run", "fork.knife", "globe",
    ]
}
