import SwiftUI
import RichTextKit

// Formatting controls for the thoughts editor. They drive RichTextKit's context,
// which applies styles to the current selection (or the typing style when nothing
// is selected) and keeps the buttons lit to match the text under the cursor.
//
// In the companion column there is no room for the full strip, and an HStack
// that cannot fit its children forces the whole window wider. So below the
// compact threshold the style toggles, sizing and clear all fold into one
// text-format menu and only the insert actions stay as buttons.
struct RichTextToolbar: View {
    @ObservedObject var context: RichTextContext
    var compact: Bool = false
    var onAddLink: () -> Void
    var onAttachImage: () -> Void
    var onCapture: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if compact {
                formatMenu
            } else {
                styleButton("bold", style: .bold, help: "Bold")
                    .keyboardShortcut("b", modifiers: .command)
                styleButton("italic", style: .italic, help: "Italic")
                    .keyboardShortcut("i", modifiers: .command)
                styleButton("underline", style: .underlined, help: "Underline")
                    .keyboardShortcut("u", modifiers: .command)
                styleButton("strikethrough", style: .strikethrough, help: "Strikethrough")
            }

            Divider().frame(height: 14).padding(.horizontal, 3)

            actionButton("link", help: "Add link") { onAddLink() }
            actionButton("photo", help: "Insert image inline") { onAttachImage() }
            actionButton("camera.viewfinder", help: "Capture screen area, placed at the cursor") { onCapture() }

            Spacer(minLength: 0)

            if !compact {
                RichTextFont.Picker(selection: $context.fontName)
                    .frame(width: 132)
                    .help("Font")

                HStack(spacing: 2) {
                    actionButton("minus", help: "Smaller text") { context.trigger(.stepFontSize(points: -1)) }
                    Text("\(Int(context.fontSize.rounded()))")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18)
                    actionButton("plus", help: "Larger text") { context.trigger(.stepFontSize(points: 1)) }
                }

                ColorPicker("", selection: context.binding(for: .foreground))
                    .labelsHidden()
                    .frame(width: 26)
                    .help("Text color")

                Divider().frame(height: 14).padding(.horizontal, 3)

                Button("Clear formatting") { clearFormatting() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // Everything the full strip offers, folded into one menu. Toggles keep the
    // native checkmark, and the shortcuts keep working from inside the menu.
    private var formatMenu: some View {
        Menu {
            Toggle("Bold", isOn: styleBinding(.bold))
                .keyboardShortcut("b", modifiers: .command)
            Toggle("Italic", isOn: styleBinding(.italic))
                .keyboardShortcut("i", modifiers: .command)
            Toggle("Underline", isOn: styleBinding(.underlined))
                .keyboardShortcut("u", modifiers: .command)
            Toggle("Strikethrough", isOn: styleBinding(.strikethrough))
            Divider()
            Button("Smaller text") { context.trigger(.stepFontSize(points: -1)) }
            Button("Larger text") { context.trigger(.stepFontSize(points: 1)) }
            Divider()
            Button("Clear formatting") { clearFormatting() }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Text formatting")
    }

    private func styleBinding(_ style: RichTextStyle) -> Binding<Bool> {
        Binding(
            get: { context.hasStyle(style) },
            set: { _ in context.toggleStyle(style) }
        )
    }

    private func clearFormatting() {
        for style in [RichTextStyle.bold, .italic, .underlined, .strikethrough] {
            context.setStyle(style, to: false)
        }
        context.setColor(.foreground, to: .labelColor)
    }

    private func styleButton(_ symbol: String, style: RichTextStyle, help: String) -> some View {
        let active = context.hasStyle(style)
        return Button {
            context.toggleStyle(style)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .help(help)
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
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
}
