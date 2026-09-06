import SwiftUI

// A reusable list of permission rows, each with a live state and a one-tap grant.
// Used in onboarding (walk them through it) and on Home (if anything is missing).
struct PermissionsChecklist: View {
    @ObservedObject var perms: Permissions
    @EnvironmentObject var calendar: CalendarManager

    var body: some View {
        VStack(spacing: 10) {
            row(icon: "mic.fill", name: "Microphone",
                detail: "Hears your side of the meeting.",
                access: perms.mic, essential: true,
                grant: { perms.requestMic() }, anchor: "Privacy_Microphone")

            row(icon: "speaker.wave.2.fill", name: "System Audio",
                detail: "Hears the other side of your call, no bot required.",
                access: perms.systemAudio, essential: true,
                grant: { perms.requestSystemAudio() }, anchor: "Privacy_AudioCapture",
                busy: perms.probingSystemAudio)

            row(icon: "rectangle.badge.checkmark", name: "Screen Recording",
                detail: "Only to capture slides or a chart into a note.",
                access: perms.screen, essential: false,
                grant: { perms.requestScreen() }, anchor: "Privacy_ScreenCapture")

            row(icon: "calendar", name: "Calendar",
                detail: "Shows today's meetings so you can start a note in one click.",
                access: calendarAccess, essential: false,
                grant: { calendar.connect() }, anchor: "Privacy_Calendars")
        }
    }

    private var calendarAccess: Permissions.Access {
        switch calendar.status {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        }
    }

    private func row(icon: String, name: String, detail: String,
                     access: Permissions.Access, essential: Bool,
                     grant: @escaping () -> Void, anchor: String, busy: Bool = false) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.record)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13.5, weight: .semibold))
                    if !essential {
                        Text("Optional")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing(access: access, busy: busy, grant: grant, anchor: anchor)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func trailing(access: Permissions.Access, busy: Bool,
                          grant: @escaping () -> Void, anchor: String) -> some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            switch access {
            case .granted:
                Label("On", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.record)
            case .denied:
                Button("Open Settings") { perms.openSettings(anchor) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            case .notDetermined:
                Button("Allow") { grant() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
    }
}

// The Home prompt shown while any permission still wants attention. Each row
// keeps its own live state, so granting one never hides the others; once the
// essentials are in, the rest is optional and the banner can be dismissed.
struct PermissionsBanner: View {
    @ObservedObject var perms: Permissions
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.record)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up Oats")
                        .font(.system(size: 15, weight: .semibold))
                    Text(perms.essentialsMissing
                         ? "Oats needs the microphone and system audio to hear both sides of a call. It only listens when you press Record, and everything stays on this Mac."
                         : "Recording is ready. The rest is optional and just makes Oats nicer to live with.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let onDismiss, !perms.essentialsMissing {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide this. Grant the rest any time in System Settings.")
                }
            }
            PermissionsChecklist(perms: perms)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }
}
