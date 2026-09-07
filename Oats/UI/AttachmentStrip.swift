import SwiftUI
import AppKit

// Horizontal row of links attached to a note. Images never appear here: captures
// and dropped images live inline in the notes editor itself.
struct AttachmentStrip: View {
    let noteID: UUID
    @Binding var attachments: [Attachment]
    var onDelete: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments.filter { $0.kind == "link" }) { attachment in
                    linkCard(attachment)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 84)
    }

    private func linkCard(_ attachment: Attachment) -> some View {
        Button {
            if let url = URL(string: attachment.value) { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(attachment.title ?? attachment.value)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(URL(string: attachment.value)?.host() ?? "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(9)
            .frame(width: 140, height: 78, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .card(radius: 10)
        .contextMenu {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(attachment.value, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete(attachment) }
        }
    }
}
