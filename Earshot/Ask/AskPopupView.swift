import SwiftUI
import AppKit

private enum Palette {
    static let panel = Color(red: 0.128, green: 0.122, blue: 0.115)   // warm near-black
    static let hairline = Color.white.opacity(0.09)
    static let field = Color.white.opacity(0.06)
    static let placeholder = Color.white.opacity(0.40)
    static let icon = Color.white.opacity(0.55)
    static let userBubble = Color.white.opacity(0.10)
}

// The summonable assistant. Compact bar by default; expands into a conversation
// once you ask something. The model is whatever the user has connected.
struct AskPopupView: View {
    @ObservedObject var controller: AskController
    @ObservedObject var agent: AgentBridge
    @FocusState private var focused: Bool

    // Editable in Settings so the quick prompts fit how each person works.
    @AppStorage("askSuggestion1") private var suggestion1 = "Summarize my last meeting"
    @AppStorage("askSuggestion2") private var suggestion2 = "List today's action items"

    private var hasText: Bool { !controller.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )

            VStack(spacing: 0) {
                if controller.mode != .compact {
                    header
                    Divider().overlay(Palette.hairline)
                    conversation
                    Divider().overlay(Palette.hairline)
                }
                composer
            }
        }
        .onAppear { focused = true }
        .onChange(of: controller.focusTick) { focused = true }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            headerButton("xmark", help: "Close (Esc)") { controller.dismiss() }

            EarshotLogoView(color: .white, size: 15)
            Text("Ask Oats")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if controller.isStreaming {
                ProgressView().controlSize(.mini).tint(Palette.icon)
            }

            Spacer()

            headerButton("arrow.up.right", help: "Open in Oats") {
                controller.openInMainWindow()
            }
            headerButton(controller.mode == .max ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: controller.mode == .max ? "Shrink" : "Maximize") {
                controller.toggleMaximize()
            }
            headerButton("square.and.pencil", help: "New chat") { controller.newChat() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.icon)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(controller.messages) { message in
                        if message.role == "user" {
                            HStack {
                                Spacer(minLength: 40)
                                Text(message.text)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(.white)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        } else if message.text.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(Palette.icon)
                                Text("Thinking with \(agent.activeAgentName)")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                MarkdownView(text: message.text)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.white.opacity(0.92))
                                if message.id != controller.messages.last?.id || !controller.isStreaming {
                                    CopyButton(text: message.text, tint: .white.opacity(0.5))
                                }
                            }
                        }
                        Color.clear.frame(height: 0).id(message.id)
                    }
                    if let error = controller.errorText {
                        Text(error)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 2).id("askBottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.messages.count) { withAnimation { proxy.scrollTo("askBottom") } }
            .onChange(of: controller.messages.last?.text) { withAnimation { proxy.scrollTo("askBottom") } }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $controller.query, prompt: Text(controller.mode == .compact ? "Ask anything, or about your meetings" : "Ask a follow-up").foregroundColor(Palette.placeholder), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { controller.submit() }

            HStack(spacing: 12) {
                ModelPickerMenu(agent: agent, tint: .white.opacity(0.8))

                if controller.mode == .compact && controller.messages.isEmpty {
                    suggestionChips
                }

                Spacer(minLength: 0)

                Button { controller.submit() } label: {
                    ZStack {
                        Circle()
                            .fill(hasText ? Theme.record : Color.white.opacity(0.14))
                            .frame(width: 30, height: 30)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hasText ? .white : .white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!hasText || controller.isStreaming)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var suggestionChips: some View {
        HStack(spacing: 7) {
            if !suggestion1.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestion(suggestion1)
            }
            if !suggestion2.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestion(suggestion2)
            }
        }
    }

    private func suggestion(_ text: String) -> some View {
        Button { controller.ask(text) } label: {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.field, in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
