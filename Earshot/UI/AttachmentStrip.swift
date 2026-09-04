import SwiftUI
import AppKit

// Horizontal strip of captures, images, and links attached to a note.
// Right-click an image to run on-device OCR; the text then feeds the summary.
struct AttachmentStrip: View {
    let noteID: UUID
    @Binding var attachments: [Attachment]

    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var capture: CaptureManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    if attachment.kind == "image" {
                        imageCard(attachment)
                    } else {
                        linkCard(attachment)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 84)
    }

    private func imageCard(_ attachment: Attachment) -> some View {
        let url = capture.imageURL(noteID: noteID, attachment)
        return Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 116, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
                    .overlay(alignment: .bottomLeading) {
                        if attachment.ocrText != nil {
                            Label("Text", systemImage: "text.viewfinder")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .glassEffect(.regular, in: .capsule)
                                .padding(4)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 116, height: 78)
            }
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            if capture.ocrInFlight.contains(attachment.id) {
                Text("Reading text")
            } else if attachment.ocrText == nil {
                Button("Read text (OCR)") {
                    Task {
                        _ = await capture.runOCR(noteID: noteID, attachment: attachment)
                        attachments = store.loadAttachments(noteID: noteID)
                    }
                }
            } else {
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(attachment.ocrText ?? "", forType: .string)
                }
            }
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Delete", role: .destructive) {
                capture.deleteAttachment(noteID: noteID, attachment)
                attachments = store.loadAttachments(noteID: noteID)
            }
        }
        .help(attachment.ocrText == nil ? "Right-click to read text from this capture" : "Text captured; it feeds the summary")
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
            Button("Delete", role: .destructive) {
                capture.deleteAttachment(noteID: noteID, attachment)
                attachments = store.loadAttachments(noteID: noteID)
            }
        }
    }
}
