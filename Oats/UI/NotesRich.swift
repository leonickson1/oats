import AppKit

// Small helpers for building and finding pieces of the notes document. The editor
// itself is RichTextKit (a proven open source rich text component); these helpers
// only construct the attributed fragments we insert through it.
enum NotesRich {
    static var font: NSFont { .systemFont(ofSize: 13.5) }

    // Custom attribute stamped on inline capture images so the exact image can be
    // found again later (to paste its text below it, or to remove it). Custom keys
    // survive every in-session edit; they are only lost across an RTFD reload,
    // where the file wrapper name takes over.
    // Deliberately keeps the original "earshot." prefix: this key is persisted
    // inside saved rich text, so renaming it would strip the filename tag from
    // captures in every note written before the rename.
    static let captureKey = NSAttributedString.Key("earshot.capture.filename")

    // An image on its own line, carried as a file wrapper so the RTFD save bundles
    // the file and so we can find this exact image again by its filename.
    static func imagePiece(url: URL) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if let wrapper = try? FileWrapper(url: url) {
            wrapper.preferredFilename = url.lastPathComponent
            attachment.fileWrapper = wrapper
        }
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            let maxWidth: CGFloat = 560
            let scale = min(1, maxWidth / image.size.width)
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            attachment.image = image
        }
        let piece = NSMutableAttributedString(string: "\n")
        let imageString = NSMutableAttributedString(attachment: attachment)
        imageString.addAttribute(captureKey, value: url.lastPathComponent, range: NSRange(location: 0, length: imageString.length))
        piece.append(imageString)
        piece.append(NSAttributedString(string: "\n"))
        piece.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: piece.length))
        return piece
    }

    // RTF cannot store dynamic colors, so the adaptive label color gets frozen to
    // plain black on save and comes back invisible on a dark background. On load,
    // any neutral (near-black or near-white, low saturation) or missing text color
    // is mapped back to the adaptive label color. Deliberate colors are kept.
    static func normalized(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let color = value as? NSColor, !isNeutral(color) { return }
            result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        return result
    }

    private static func isNeutral(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
        let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
        let grayish = (hi - lo) < 0.15
        return grayish && (hi < 0.35 || lo > 0.85)
    }

    // A block of plain text on its own line, in the notes font.
    static func textPiece(_ text: String) -> NSAttributedString {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSAttributedString(
            string: "\n" + clean + "\n",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }
}

extension NSAttributedString {
    // The character range of the inline image whose file name matches, if the image
    // is in the document. Used to insert its captured text right below it, and to
    // remove it when the capture is deleted. The capture stamp is checked first
    // (reliable in session), then the file wrapper name (survives an RTFD reload).
    func rangeOfAttachment(filename: String) -> NSRange? {
        var found: NSRange?
        enumerateAttribute(NotesRich.captureKey, in: NSRange(location: 0, length: length)) { value, range, stop in
            if (value as? String) == filename {
                found = range
                stop.pointee = true
            }
        }
        if let found { return found }
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            if attachment.fileWrapper?.preferredFilename == filename || attachment.fileWrapper?.filename == filename {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // The capture file name of any inline image inside the given range, if one is
    // there. Drives the paste-its-text offer when the user selects an image.
    func captureFilename(in range: NSRange) -> String? {
        let location = min(range.location, length)
        let safe = NSRange(location: location, length: min(range.length, length - location))
        guard safe.length > 0 else { return nil }
        var found: String?
        enumerateAttribute(NotesRich.captureKey, in: safe) { value, _, stop in
            if let name = value as? String {
                found = name
                stop.pointee = true
            }
        }
        if found == nil {
            enumerateAttribute(.attachment, in: safe) { value, _, stop in
                guard let attachment = value as? NSTextAttachment else { return }
                if let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename {
                    found = name
                    stop.pointee = true
                }
            }
        }
        return found
    }
}
