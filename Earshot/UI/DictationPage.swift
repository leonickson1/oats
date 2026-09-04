import SwiftUI
import AppKit

struct DictationPage: View {
    @EnvironmentObject var dictation: DictationController
    @State private var accessibilityGranted = TextInserter.hasAccessibility

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Dictation")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 48)

                Text("Press Opt+Period anywhere, speak, then press it again or hit the check mark. Your words are transcribed on this Mac and typed into whatever app you were using.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 520, alignment: .leading)

                statusCard

                if dictation.isActive {
                    HStack(spacing: 10) {
                        WaveformBars(levels: dictation.levels, barColor: Theme.ink)
                            .frame(width: 64, height: 22)
                        Text(dictation.liveText.isEmpty ? "Listening" : dictation.liveText)
                            .font(.system(size: 13))
                            .foregroundStyle(dictation.liveText.isEmpty ? Theme.tertiary : Theme.ink)
                            .lineLimit(3)
                    }
                    .padding(14)
                    .frame(maxWidth: 520, alignment: .leading)
                    .hairlineCard()
                }

                if let error = dictation.lastError {
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.destructive)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                if !dictation.history.isEmpty {
                    Text("Recent dictations")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)
                    VStack(spacing: 1) {
                        ForEach(Array(dictation.history.enumerated()), id: \.offset) { _, text in
                            HStack(alignment: .top, spacing: 10) {
                                Text(text)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .frame(maxWidth: 520)
                    .hairlineCard()
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(timer) { _ in
            accessibilityGranted = TextInserter.hasAccessibility
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: accessibilityGranted ? "checkmark.circle" : "hand.raised")
                .font(.system(size: 15))
                .foregroundStyle(accessibilityGranted ? Theme.recordGreen : Theme.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(accessibilityGranted ? "Auto-insert is on" : "Auto-insert needs Accessibility access")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(accessibilityGranted
                     ? "Dictated text is typed straight into the focused app."
                     : "Without it, dictated text is copied to the clipboard instead. Grant access in System Settings > Privacy & Security > Accessibility.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if !accessibilityGranted {
                Button("Grant access") { TextInserter.promptForAccessibility() }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .hairlineCard()
    }
}
