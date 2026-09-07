import SwiftUI

// The floating lozenge. Oats's own take: a tiny quiet capsule that only
// grows when you need it, and everything it shows is real signal.
//   idle collapsed:      small capsule with the Oats mark
//   idle expanded:       [record] [open notes]        (on hover)
//   call detected:       [call card] [take notes] [dismiss]
//   recording collapsed: live bars + elapsed time
//   recording expanded:  [bars + time] [pause] [stop] [notes]
//
// Legibility is the system's job, the way Apple designs Liquid Glass: the pill is
// the Regular glass variant, which "continuously adapts based on what's behind
// it" and flips light/dark on its own, and every glyph and label rides the
// material's vibrancy so it flips with it (WWDC25 "Meet Liquid Glass": all
// content on the Regular variant automatically receives this treatment). So we
// never bake a color or sample the screen; we render vibrant .primary/.secondary
// content and let macOS keep it readable over white pages, video, or dark walls.
struct HUDView: View {
    @ObservedObject var app: AppState
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var meetings: MeetingDetector
    @State private var hovering = false
    @Namespace private var glassNS

    init(app: AppState) {
        self.app = app
        self.recorder = app.recorder
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: recorder.isActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: recorder.isPaused)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: meetings.current)
    }

    // MARK: - Adaptive glass

    // Bare Liquid Glass, no tint: the Regular material provides legibility over
    // any content on its own, and the untinted material keeps the true
    // translucent look. Content on top uses vibrant styles so it flips with it.
    private var glass: Glass { .regular }
    private var glassInteractive: Glass { glass.interactive() }

    // MARK: - Idle

    private var idleLozenge: some View {
        EarshotGlyphView(size: 16)
            .foregroundStyle(.primary)
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
                // Icon-only, dead-centered in the elliptical capsule. A frame
                // centers its child by default, so the record glyph sits in the
                // middle instead of hugging the leading edge.
                RecordGlyph(color: Theme.record, size: 15)
                    .frame(width: 52, height: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(glassInteractive, in: .capsule)
            .glassEffectID("core", in: glassNS)
            .help("New note  Opt+M")

            Button {
                app.showMainWindow()
            } label: {
                EarshotGlyphView(size: 15)
                    .foregroundStyle(.primary)
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
    // action on the right. The action is a solid record-red fill (a fill on top
    // of glass, not glass-on-glass), so it reads as the primary "do this" pill
    // over any backdrop without depending on a light/dark flip.
    private func callOffer(_ call: MeetingDetector.Detection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: call.isBrowser ? "video.fill" : "phone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Call detected")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(call.appName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Button {
                meetings.dismiss()
                app.startMeetingNote(companion: true)
            } label: {
                HStack(spacing: 7) {
                    RecordGlyph(color: .white, size: 12)
                    Text("Take notes")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(.white)
                .frame(height: 36)
                .padding(.horizontal, 16)
                .background(Theme.record, in: Capsule())
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
                    .foregroundStyle(.secondary)
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
            EarshotGlyphView(size: 14)
                .foregroundStyle(recorder.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.record))
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
                .foregroundStyle(.primary)
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
                    .foregroundStyle(.primary)
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
                EarshotGlyphView(size: 13)
                    .foregroundStyle(.primary)
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
