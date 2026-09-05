import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Turn a meeting into something you can take elsewhere: Markdown (copy or file)
// and PDF. Everything is built from the plain files already on disk.
@MainActor
enum ExportService {

    // Assemble a clean Markdown document: title, date, summary, action items,
    // and the transcript.
    static func markdown(noteID: UUID, store: NoteStore, includeTranscript: Bool = true) -> String {
        let meta = store.meta(id: noteID)
        let title = meta?.title ?? "Meeting"
        var out = "# \(title)\n"
        if let date = meta?.createdAt {
            out += "_\(date.formatted(date: .complete, time: .shortened))_\n"
        }
        out += "\n"

        let summary = store.loadSummary(noteID: noteID)
        if !summary.isEmpty {
            out += summary.hasPrefix("#") ? summary : "## Summary\n\(summary)"
            out += "\n\n"
        }

        let actions = store.loadActions(noteID: noteID)
        if !actions.isEmpty {
            out += "## Action items\n"
            for item in actions {
                let box = item.done ? "[x]" : "[ ]"
                let owner = (item.owner?.isEmpty == false) ? " (\(item.owner!))" : ""
                out += "- \(box) \(item.text)\(owner)\n"
            }
            out += "\n"
        }

        if includeTranscript {
            let segments = store.loadSegments(noteID: noteID).filter { $0.channel != "system" }
            if !segments.isEmpty {
                out += "## Transcript\n"
                for s in segments {
                    let who = s.channel == "me" ? "Me" : "Them"
                    out += "**[\(s.t.clockString)] \(who):** \(s.text)\n\n"
                }
            }
        }
        return out
    }

    static func copyMarkdown(noteID: UUID, store: NoteStore) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(noteID: noteID, store: store), forType: .string)
    }

    static func saveMarkdown(noteID: UUID, store: NoteStore) {
        let text = markdown(noteID: noteID, store: store)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(safeName(noteID: noteID, store: store)).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func savePDF(noteID: UUID, store: NoteStore) {
        let text = markdown(noteID: noteID, store: store)
        guard let data = pdfData(markdown: text) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(safeName(noteID: noteID, store: store)).pdf"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    // MARK: - Internals

    private static func safeName(noteID: UUID, store: NoteStore) -> String {
        let title = store.meta(id: noteID)?.title ?? "Meeting"
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return cleaned.isEmpty ? "Meeting" : cleaned
    }

    private static func pdfData(markdown: String) -> Data? {
        let page = ExportDocument(text: markdown).frame(width: 540)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(width: 540, height: nil)
        let data = NSMutableData()
        renderer.render { size, drawInContext in
            var box = CGRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1))
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            drawInContext(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
        }
        return data.isEmpty ? nil : (data as Data)
    }
}

// A light, printable page rendered to PDF. Fixed light palette so it reads on
// paper regardless of the app's theme.
private struct ExportDocument: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownView(text: text, textSize: 12, accent: .black)
                .environment(\.colorScheme, .light)
                .foregroundStyle(.black)
        }
        .padding(36)
        .frame(width: 540, alignment: .leading)
        .background(Color.white)
    }
}
