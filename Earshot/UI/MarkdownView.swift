import SwiftUI
import AppKit
import AVFoundation

// Renders markdown as real formatted views: headings, bullet and numbered lists,
// checkboxes, code blocks, quotes, rules, links, images, and inline bold/italic.
// Standalone images and audio links become actual pictures and a play control, so
// anything an agent generates can be seen and heard in place. Used everywhere a
// model reply is shown: the note summary, the in-note chat, the home answer, and
// the Ask popup.
struct MarkdownView: View {
    let text: String
    var textSize: CGFloat = 13.5
    var accent: Color = Theme.record

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .medium))
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            inline(content)
                .font(.system(size: textSize))
                .lineSpacing(3)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: .bullet, checkbox: item.checkbox, content: item.text)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: .number(index + 1), checkbox: nil, content: item.text)
                }
            }

        case .quote(let content):
            HStack(spacing: 10) {
                Capsule().fill(accent.opacity(0.6)).frame(width: 3)
                inline(content)
                    .font(.system(size: textSize))
                    .foregroundStyle(.secondary)
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: textSize - 1, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .rule:
            Divider().opacity(0.5).padding(.vertical, 2)

        case .image(let alt, let url):
            MarkdownImage(alt: alt, url: url)

        case .audio(let title, let url):
            InlineAudioPlayer(title: title, url: url, accent: accent)
        }
    }

    private enum Marker { case bullet, number(Int) }

    @ViewBuilder
    private func listRow(marker: Marker, checkbox: Bool?, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let checkbox {
                Image(systemName: checkbox ? "checkmark.square.fill" : "square")
                    .font(.system(size: textSize - 1))
                    .foregroundStyle(checkbox ? accent : Color.secondary)
            } else {
                switch marker {
                case .bullet:
                    Text("•").font(.system(size: textSize)).foregroundStyle(.secondary)
                case .number(let n):
                    Text("\(n).").font(.system(size: textSize - 0.5, weight: .medium)).foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                }
            }
            inline(content)
                .font(.system(size: textSize))
                .lineSpacing(2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inline(_ s: String) -> Text {
        Text(MarkdownParser.inlineAttributed(s))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return textSize + 7
        case 2: return textSize + 4
        case 3: return textSize + 2
        default: return textSize + 1
        }
    }
}

// MARK: - Media

private struct MarkdownImage: View {
    let alt: String
    let url: String

    var body: some View {
        Group {
            if let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: fallback
                    case .empty: ProgressView().frame(height: 80)
                    @unknown default: fallback
                    }
                }
            } else if let local = MarkdownParser.localURL(url), let nsImage = NSImage(contentsOf: local) {
                Image(nsImage: nsImage).resizable().scaledToFit()
            } else {
                fallback
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { open() }
        .help(alt.isEmpty ? "Open image" : alt)
    }

    private var fallback: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
            Text(alt.isEmpty ? url : alt).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func open() {
        if let u = URL(string: url), u.scheme?.hasPrefix("http") == true { NSWorkspace.shared.open(u) }
        else if let local = MarkdownParser.localURL(url) { NSWorkspace.shared.open(local) }
    }
}

// A compact inline player for audio the model produced or referenced.
private struct InlineAudioPlayer: View {
    let title: String
    let url: String
    var accent: Color

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Audio" : title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("Tap to play")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                if let u = resolvedURL { NSWorkspace.shared.open(u) }
            } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in default app")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDisappear { player?.pause() }
    }

    private var resolvedURL: URL? {
        if let u = URL(string: url), u.scheme?.hasPrefix("http") == true { return u }
        return MarkdownParser.localURL(url)
    }

    private func toggle() {
        if player == nil, let u = resolvedURL { player = AVPlayer(url: u) }
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }
}
