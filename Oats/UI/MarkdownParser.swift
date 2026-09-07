import Foundation

struct MDListItem {
    let text: String
    let checkbox: Bool?   // nil = plain bullet, true/false = checked/unchecked task
}

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([MDListItem])
    case numbered([MDListItem])
    case quote(String)
    case code(String)
    case rule
    case image(alt: String, url: String)
    case audio(title: String, url: String)
}

// A small, dependency-free block-level markdown parser. It exists because
// SwiftUI's Text renders AttributedString markdown inline only, so headings and
// lists show up as literal "##" and "-". Inline styling (bold/italic/code/links)
// is still handled by AttributedString within each block.
enum MarkdownParser {
    static func parse(_ input: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var para: [String] = []
        var bullets: [MDListItem] = []
        var numbered: [MDListItem] = []
        var quote: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
        }
        func flushNumbered() {
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushBullets(); flushNumbered(); flushQuote() }

        for rawLine in input.components(separatedBy: .newlines) {
            let t = rawLine.trimmingCharacters(in: .whitespaces)

            // Code fences.
            if t.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushAll()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(rawLine); continue }

            if t.isEmpty { flushAll(); continue }

            // Horizontal rule.
            if t == "---" || t == "***" || t == "___" {
                flushAll(); blocks.append(.rule); continue
            }

            // Heading.
            if let r = t.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushAll()
                let level = t.distance(from: t.startIndex, to: t.firstIndex(where: { $0 != "#" }) ?? t.startIndex)
                let content = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(max(level, 1), 6), text: content))
                continue
            }

            // Standalone media: ![alt](url) or a link to an image/audio file.
            if let media = standaloneMedia(t) {
                flushAll(); blocks.append(media); continue
            }

            // Bullet list (including task checkboxes).
            if let r = t.range(of: "^[-*+]\\s+", options: .regularExpression) {
                flushParagraph(); flushNumbered(); flushQuote()
                bullets.append(listItem(String(t[r.upperBound...])))
                continue
            }

            // Numbered list.
            if let r = t.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                flushParagraph(); flushBullets(); flushQuote()
                numbered.append(listItem(String(t[r.upperBound...])))
                continue
            }

            // Blockquote.
            if t.hasPrefix(">") {
                flushParagraph(); flushBullets(); flushNumbered()
                quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            // Paragraph text.
            flushBullets(); flushNumbered(); flushQuote()
            para.append(t)
        }

        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func listItem(_ raw: String) -> MDListItem {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[ ] ") { return MDListItem(text: String(s.dropFirst(4)), checkbox: false) }
        if s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { return MDListItem(text: String(s.dropFirst(4)), checkbox: true) }
        return MDListItem(text: s, checkbox: nil)
    }

    // Detects a line that is only an image or only a media link, so it can be
    // rendered as a picture or a player instead of literal markdown.
    private static func standaloneMedia(_ line: String) -> MDBlock? {
        if line.hasPrefix("!"), let (alt, url) = linkParts(String(line.dropFirst())) {
            return isAudio(url) ? .audio(title: alt, url: url) : .image(alt: alt, url: url)
        }
        if let (label, url) = linkParts(line) {
            if isImage(url) { return .image(alt: label, url: url) }
            if isAudio(url) { return .audio(title: label, url: url) }
        }
        return nil
    }

    // Parses "[label](url)" if that is the entire string. Returns nil otherwise.
    private static func linkParts(_ s: String) -> (String, String)? {
        let str = s.trimmingCharacters(in: .whitespaces)
        guard str.hasPrefix("["), str.hasSuffix(")"),
              let closeBracket = str.firstIndex(of: "]") else { return nil }
        let afterBracket = str.index(after: closeBracket)
        guard afterBracket < str.endIndex, str[afterBracket] == "(" else { return nil }
        let label = String(str[str.index(after: str.startIndex)..<closeBracket])
        let url = String(str[str.index(after: afterBracket)..<str.index(before: str.endIndex)])
        guard !url.isEmpty, !url.contains(" ") else { return nil }
        return (label, url)
    }

    private static func ext(_ url: String) -> String {
        let noQuery = url.split(separator: "?").first.map(String.init) ?? url
        return (noQuery as NSString).pathExtension.lowercased()
    }

    private static func isImage(_ url: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"].contains(ext(url))
    }

    private static func isAudio(_ url: String) -> Bool {
        ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf", "ogg"].contains(ext(url))
    }

    static func localURL(_ url: String) -> URL? {
        if url.hasPrefix("file://") { return URL(string: url) }
        if url.hasPrefix("~") { return URL(fileURLWithPath: (url as NSString).expandingTildeInPath) }
        if url.hasPrefix("/") { return URL(fileURLWithPath: url) }
        return nil
    }

    // Inline styling (bold, italic, code, links, strikethrough) for one block.
    static func inlineAttributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
