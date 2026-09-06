import SwiftUI

// The floating lozenge. Oats's own take: a tiny quiet capsule that only
// grows when you need it, and everything it shows is real signal.
//   idle collapsed:      small capsule with the Oats mark
//   idle expanded:       [record] [open notes]        (on hover)
//   call detected:       [call card] [take notes] [dismiss]
//   recording collapsed: live bars + elapsed time
//   recording expanded:  [bars + time] [pause] [stop] [notes]
// The pill adapts to what is behind it, like native glass: over dark content it
// is a dark pill with light ink, over a white page a light pill with dark ink.
struct HUDView: View {
    @ObservedObject var app: AppState
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var backdrop: HUDBackdrop
    @ObservedObject var meetings: MeetingDetector
    @State private var hovering = false
    @Namespace private var glassNS

    init(app: AppState) {
        self.app = app
        self.recorder = app.recorder
        self.backdrop = app.backdrop
        self.meetings = app.meetings
    }

    private var expanded: Bool { hovering }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if recorder.isActive {
                    recordingLozenge
                    if expanded { recordingControls }
                } else if let call = meetings.current {
                    callOffer(call)
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
        // The whole pill renders in the scheme of what is behind it: light glass
        // with dark ink over a white page, dark glass with light ink otherwise.
        // Vibrancy and the glass material both key off the scheme, so every
        // glyph flips together, the way native controls adapt to the wallpaper.
        .environment(\.colorScheme, backdrop.overLight ? .light : .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: recorder.isActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: recorder.isPaused)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: meetings.current)
        .animation(.easeInOut(duration: 0.3), value: backdrop.overLight)
    }

    // MARK: - Adaptive glass

    // A tint in the scheme's own direction keeps the pill reading solid on busy
    // backgrounds without fighting the adaptive material.
    private var glass: Glass {
        backdrop.overLight ? Glass.regular.tint(.white.opacity(0.45)) : Glass.regular.tint(.black.opacity(0.55))
    }
    private var glassInteractive: Glass { glass.interactive() }
    // Explicit, not .primary: the logo bakes its color into an SVG through
    // NSColor, which resolves semantic colors against the app's appearance
    // (dark), not the panel's, and would come out white on the light pill.
    private var ink: Color { backdrop.overLight ? .black.opacity(0.85) : .white }
    private var inkSecondary: Color { backdrop.overLight ? .black.opacity(0.55) : .white.opacity(0.62) }

    // MARK: - Idle

    private var idleLozenge: some View {
        EarshotLogoView(color: ink, size: 16)
            .frame(width: 46, height: 26)
            .contentShape(Capsule())
            .glassEffect(glass, in: .capsule)
            .glassEffectID("core", in: glassNS)
            .help("Oats")
    }

    private var idleExpanded: some View {
        HStack(spacing: 8) {
            Button {
                app.startMeetingNote(companion: true)
            } label: {
                HStack(spacing: 7) {
                    RecordGlyph(color: Theme.record, size: 13)
                    Text("Record")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(ink)
                .frame(height: 30)
                .padding(.horizontal, 13)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(glassInteractive, in: .capsule)
            .glassEffectID("core", in: glassNS)
            .help("New note  Opt+M")

            Button {
                app.showMainWindow()
            } label: {
                EarshotLogoView(color: ink, size: 15)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(glassInteractive, in: .circle)
            .glassEffectID("notes", in: glassNS)
            .help("Open Oats")
        }
    }

    // MARK: - Call detected

    // One card, Granola-style: what happened on the left, a single prominent
    // action on the right. The button inverts the card's ink so it reads as
    // the native "do this" pill in both light and dark states.
    private func callOffer(_ call: MeetingDetector.Detection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: call.isBrowser ? "video.fill" : "phone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
            VStack(alignment: .leading, spacing: 1) {
                Text("Call detected")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ink)
                Text(call.appName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(inkSecondary)
            }
            .fixedSize()

            Button {
                meetings.dismiss()
                app.startMeetingNote(companion: true)
            } label: {
                HStack(spacing: 7) {
                    RecordGlyph(color: Theme.record, size: 12)
                    Text("Take notes")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(backdrop.overLight ? .white : Color.black.opacity(0.85))
                .frame(height: 36)
                .padding(.horizontal, 16)
                .background(backdrop.overLight ? Color.black.opacity(0.85) : .white, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .help("Start a meeting note for this call")

            Button {
                meetings.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(inkSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .contentShape(Capsule())
        .glassEffect(glass, in: .capsule)
        .glassEffectID("core", in: glassNS)
    }

    // MARK: - Recording

    private var recordingLozenge: some View {
        HStack(spacing: 8) {
            EarshotLogoView(color: recorder.isPaused ? inkSecondary : Theme.record, size: 14)
            if recorder.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(inkSecondary)
            } else {
                WaveformBars(levels: recorder.levels, barColor: Theme.record, barCount: 7, maxHeight: 12)
            }
            Text(recorder.elapsed.clockString)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 28)
        .contentShape(Capsule())
        .glassEffect(glass, in: .capsule)
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
                    .foregroundStyle(ink)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(glassInteractive, in: .circle)
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
            .glassEffect(glassInteractive, in: .circle)
            .glassEffectID("stop", in: glassNS)
            .help("Stop and summarize")

            Button {
                app.showCurrentNoteWindow()
            } label: {
                EarshotLogoView(color: ink, size: 13)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(glassInteractive, in: .circle)
            .glassEffectID("notes", in: glassNS)
            .help("Open note")
        }
    }
}
