import SwiftUI

// The floating lozenge. Oats's own take: a tiny quiet capsule that only
// grows when you need it, and everything it shows is real signal.
//   idle collapsed:      small capsule with the Oats mark
//   idle expanded:       [record] [open notes]        (on hover)
//   recording collapsed: live bars + elapsed time
//   recording expanded:  [bars + time] [pause] [stop] [notes]
struct HUDView: View {
    @ObservedObject var app: AppState
    @ObservedObject var recorder: MeetingRecorder
    @State private var hovering = false
    @Namespace private var glassNS

    init(app: AppState) {
        self.app = app
        self.recorder = app.recorder
    }

    private var expanded: Bool { hovering }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if recorder.isActive {
                    recordingLozenge
                    if expanded { recordingControls }
                } else {
                    if expanded {
                        idleExpanded
                    } else {
                        idleLozenge
                    }
                }
            }
        }
        .padding(10)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: recorder.isActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: recorder.isPaused)
    }

    // MARK: - Idle

    // A dark tint keeps the glass reading as a solid dark pill even over a bright
    // window, so the white mark never washes out on a white background.
    private static let darkGlass = Glass.regular.tint(.black.opacity(0.55))
    private static let darkGlassInteractive = Glass.regular.tint(.black.opacity(0.55)).interactive()

    private var idleLozenge: some View {
        EarshotLogoView(color: .white, size: 16)
            .frame(width: 46, height: 26)
            .contentShape(Capsule())
            .glassEffect(Self.darkGlass, in: .capsule)
            .glassEffectID("core", in: glassNS)
            .help("Oats")
    }

    private var idleExpanded: some View {
        HStack(spacing: 8) {
            Button {
                app.startMeetingNote()
            } label: {
                HStack(spacing: 7) {
                    RecordGlyph(color: Theme.record, size: 13)
                    Text("Record")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(height: 30)
                .padding(.horizontal, 13)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(Self.darkGlassInteractive, in: .capsule)
            .glassEffectID("core", in: glassNS)
            .help("New note  Opt+M")

            Button {
                app.showMainWindow()
            } label: {
                EarshotLogoView(color: .white, size: 15)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(Self.darkGlassInteractive, in: .circle)
            .glassEffectID("notes", in: glassNS)
            .help("Open Oats")
        }
    }

    // MARK: - Recording

    private var recordingLozenge: some View {
        HStack(spacing: 8) {
            EarshotLogoView(color: recorder.isPaused ? .secondary : Theme.record, size: 14)
            if recorder.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                WaveformBars(levels: recorder.levels, barColor: Theme.record, barCount: 7, maxHeight: 12)
            }
            Text(recorder.elapsed.clockString)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 28)
        .contentShape(Capsule())
        .glassEffect(Self.darkGlass, in: .capsule)
        .glassEffectID("core", in: glassNS)
        .onTapGesture { app.showCurrentNoteWindow() }
        .help(recorder.isPaused ? "Paused" : "Recording")
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Button {
                if recorder.isPaused { recorder.resume() } else { recorder.pause() }
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(Self.darkGlassInteractive, in: .circle)
            .glassEffectID("pause", in: glassNS)
            .help(recorder.isPaused ? "Resume" : "Pause")

            Button {
                app.stopMeetingNote()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.record)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(Self.darkGlassInteractive, in: .circle)
            .glassEffectID("stop", in: glassNS)
            .help("Stop and summarize")

            Button {
                app.showCurrentNoteWindow()
            } label: {
                EarshotLogoView(color: .white, size: 13)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(Self.darkGlassInteractive, in: .circle)
            .glassEffectID("notes", in: glassNS)
            .help("Open note")
        }
    }
}
