import SwiftUI

// The floating pill cluster. Three states:
//   idle:      [dictation mic] [record] [notepad]
//   dictating: [cancel] [waveform] [accept]
//   meeting:   [waveform + stop] [notepad]
struct HUDView: View {
    @ObservedObject var app: AppState
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var dictation: DictationController

    init(app: AppState) {
        self.app = app
        self.recorder = app.recorder
        self.dictation = app.dictation
    }

    var body: some View {
        HStack(spacing: 8) {
            if dictation.isActive {
                dictatingCluster
            } else if recorder.isActive {
                meetingCluster
            } else {
                idleCluster
            }
        }
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dictation.isActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: recorder.isActive)
    }

    // MARK: - Idle

    private var idleCluster: some View {
        HStack(spacing: 7) {
            hudButton(systemName: "mic.fill", help: "Dictate  Opt+Period") {
                dictation.toggle()
            }
            HStack(spacing: 2) {
                hudButton(systemName: "record.circle", help: "New note  Opt+M") {
                    app.startMeetingNote()
                }
                Button {
                    app.showMainWindow()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.hudText.opacity(0.7))
                        .frame(width: 18, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Earshot")
            }
            .background(Theme.hudBG)
            .clipShape(Capsule())
            hudButton(systemName: "note.text", help: "Show notepad") {
                app.showMainWindow()
            }
        }
    }

    // MARK: - Dictating

    private var dictatingCluster: some View {
        HStack(spacing: 6) {
            Button {
                Task { await dictation.cancel() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.hudText)
                    .frame(width: 30, height: 30)
                    .background(Theme.hudSubtle)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")

            WaveformBars(levels: dictation.levels)
                .frame(width: 64, height: 22)

            Button {
                Task { await dictation.accept() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.hudBG)
                    .frame(width: 30, height: 30)
                    .background(Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Insert text")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Theme.hudBG)
        .clipShape(Capsule())
    }

    // MARK: - Meeting

    private var meetingCluster: some View {
        HStack(spacing: 7) {
            HStack(spacing: 10) {
                WaveformBars(levels: recorder.levels)
                    .frame(width: 56, height: 22)
                Button {
                    app.stopMeetingNote()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.hudBG)
                        .frame(width: 26, height: 26)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop recording")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.hudBG)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .clipShape(Capsule())

            hudButton(systemName: "note.text", help: "Show notepad") {
                app.showCurrentNoteWindow()
            }
        }
    }

    // MARK: - Pieces

    private func hudButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.hudText)
                .frame(width: 34, height: 34)
                .background(Theme.hudBG)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
