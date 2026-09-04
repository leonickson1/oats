import SwiftUI

// Native rich text controls for the thoughts editor. Uses the macOS 26
// AttributedString TextEditor APIs; formatting is stored in the note itself.
struct RichTextToolbar: View {
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection
    var onAddLink: () -> Void
    var onAttachImage: () -> Void
    var onCapture: () -> Void

    @Environment(\.fontResolutionContext) private var fontContext

    var body: some View {
        HStack(spacing: 4) {
            formatButton("bold", help: "Bold") { toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
            formatButton("italic", help: "Italic") { toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
            formatButton("underline", help: "Underline") { toggleUnderline() }
                .keyboardShortcut("u", modifiers: .command)
            formatButton("strikethrough", help: "Strikethrough") { toggleStrikethrough() }

            Divider().frame(height: 14).padding(.horizontal, 3)

            formatButton("link", help: "Add link") { onAddLink() }
            formatButton("photo", help: "Attach image") { onAttachImage() }
            formatButton("camera.viewfinder", help: "Capture screen area") { onCapture() }

            Spacer()

            Button("Clear formatting") { clearFormatting() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Transforms

    private func toggleBold() {
        text.transformAttributes(in: &selection) { container in
            let font = container.font ?? .body
            let isBold = font.resolve(in: fontContext).isBold
            container.font = font.bold(!isBold)
        }
    }

    private func toggleItalic() {
        text.transformAttributes(in: &selection) { container in
            let font = container.font ?? .body
            let isItalic = font.resolve(in: fontContext).isItalic
            container.font = font.italic(!isItalic)
        }
    }

    private func toggleUnderline() {
        text.transformAttributes(in: &selection) { container in
            container.underlineStyle = container.underlineStyle == nil ? .single : nil
        }
    }

    private func toggleStrikethrough() {
        text.transformAttributes(in: &selection) { container in
            container.strikethroughStyle = container.strikethroughStyle == nil ? .single : nil
        }
    }

    private func clearFormatting() {
        text.transformAttributes(in: &selection) { container in
            container.font = nil
            container.underlineStyle = nil
            container.strikethroughStyle = nil
            container.foregroundColor = nil
            container.link = nil
        }
    }
}
