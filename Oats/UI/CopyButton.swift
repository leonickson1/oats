import SwiftUI
import AppKit

// Copies text to the clipboard with a brief "Copied" confirmation. Used under
// every model answer (note chat, summary, home, Ask popup).
struct CopyButton: View {
    let text: String
    var compact = false
    var tint: Color = .secondary

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Theme.record : tint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            } else {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Theme.record : tint)
            }
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
