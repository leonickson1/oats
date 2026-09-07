import Foundation
import AppKit
import Vision
import LinkPresentation

// Screen captures and link attachments for notes.
// Capture: the user drags a region (a slide in Zoom, a chart in a video) and
// the image lands in the note. OCR runs on-device via Vision, and the text
// feeds the summary so slides become part of the meeting record.
@MainActor
final class CaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var ocrInFlight: Set<UUID> = []

    unowned let store: NoteStore

    init(store: NoteStore) {
        self.store = store
    }

    // MARK: - Screen capture (interactive region, like Shift+Cmd+4)

    func captureRegion(noteID: UUID, at t: TimeInterval, inline: Bool = false) async -> Attachment? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let filename = "capture-\(Int(Date().timeIntervalSince1970)).png"
        let destination = store.assetsDir(for: noteID).appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x no sound, -o no window shadow
        process.arguments = ["-i", "-x", "-o", destination.path]
        do {
            try process.run()
        } catch {
            return nil
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }

        let attachment = Attachment(kind: "image", value: filename, t: t, inline: inline)
        store.appendAttachment(noteID: noteID, attachment)
        autoOCR(noteID: noteID, attachment: attachment)
        return attachment
    }

    // Read text off every capture automatically so it always feeds the summary,
    // no right-click required. Idempotent and off the main thread.
    private func autoOCR(noteID: UUID, attachment: Attachment) {
        Task { _ = await runOCR(noteID: noteID, attachment: attachment) }
    }

    // MARK: - Image files (drag and drop or file picker)

    @discardableResult
    func addImage(noteID: UUID, from sourceURL: URL, at t: TimeInterval, inline: Bool = false) -> URL? {
        let filename = "image-\(Int(Date().timeIntervalSince1970))-\(sourceURL.lastPathComponent)"
        let destination = store.assetsDir(for: noteID).appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return nil
        }
        let attachment = Attachment(kind: "image", value: filename, t: t, inline: inline)
        store.appendAttachment(noteID: noteID, attachment)
        autoOCR(noteID: noteID, attachment: attachment)
        return destination
    }

    func addImage(noteID: UUID, imageData: Data, at t: TimeInterval) {
        let filename = "image-\(Int(Date().timeIntervalSince1970)).png"
        let destination = store.assetsDir(for: noteID).appendingPathComponent(filename)
        guard (try? imageData.write(to: destination)) != nil else { return }
        let attachment = Attachment(kind: "image", value: filename, t: t)
        store.appendAttachment(noteID: noteID, attachment)
        autoOCR(noteID: noteID, attachment: attachment)
    }

    // MARK: - Links (title fetched natively via LinkPresentation)

    func addLink(noteID: UUID, urlString: String, at t: TimeInterval) {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), url.host() != nil else { return }
        let attachment = Attachment(kind: "link", value: url.absoluteString, title: url.host(), t: t)
        store.appendAttachment(noteID: noteID, attachment)

        let provider = LPMetadataProvider()
        provider.timeout = 8
        Task { [weak self] in
            guard let metadata = try? await provider.startFetchingMetadata(for: url),
                  let title = metadata.title, !title.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                var all = self.store.loadAttachments(noteID: noteID)
                if let idx = all.firstIndex(where: { $0.id == attachment.id }) {
                    all[idx].title = title
                    self.store.saveAttachments(noteID: noteID, all)
                }
            }
        }
    }

    // MARK: - OCR (on-device, Vision)

    func runOCR(noteID: UUID, attachment: Attachment) async -> String? {
        guard attachment.kind == "image", !ocrInFlight.contains(attachment.id) else { return attachment.ocrText }
        ocrInFlight.insert(attachment.id)
        defer { ocrInFlight.remove(attachment.id) }

        let imageURL = store.assetsDir(for: noteID).appendingPathComponent(attachment.value)
        let text: String? = await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: imageURL)
            guard (try? handler.perform([request])) != nil else { return nil }
            let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value

        guard let text else { return nil }
        var all = store.loadAttachments(noteID: noteID)
        if let idx = all.firstIndex(where: { $0.id == attachment.id }) {
            all[idx].ocrText = text
            store.saveAttachments(noteID: noteID, all)
        }
        return text
    }

    func deleteAttachment(noteID: UUID, _ attachment: Attachment) {
        if attachment.kind == "image" {
            try? FileManager.default.removeItem(at: store.assetsDir(for: noteID).appendingPathComponent(attachment.value))
        }
        store.saveAttachments(noteID: noteID, store.loadAttachments(noteID: noteID).filter { $0.id != attachment.id })
    }

    func imageURL(noteID: UUID, _ attachment: Attachment) -> URL {
        store.assetsDir(for: noteID).appendingPathComponent(attachment.value)
    }
}
