import Foundation
import EventKit

// Pulls a video-call link out of a calendar event so Home can offer "Join &
// Record" instead of a plain "Record". Calendars stash the join URL in a few
// places (the dedicated url field, the location, or somewhere in the notes),
// so we check all three and only accept links from known meeting providers.
enum MeetingLink {
    // Host fragments we recognize as a live meeting. Matched as a suffix or a
    // substring so subdomains (us02web.zoom.us) and paths still count.
    private static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co", "chime.aws",
        "bluejeans.com", "gotomeeting.com", "8x8.vc"
    ]

    static func detect(in event: EKEvent) -> URL? {
        if let u = event.url, matches(u) { return u }
        if let u = firstMeetingURL(in: event.location) { return u }
        if let u = firstMeetingURL(in: event.notes) { return u }
        return nil
    }

    // A short human label for the provider, e.g. "Zoom", "Google Meet".
    static func providerName(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("zoom.us") { return "Zoom" }
        if host.contains("meet.google.com") { return "Google Meet" }
        if host.contains("teams.") { return "Teams" }
        if host.contains("webex.com") { return "Webex" }
        if host.contains("whereby.com") { return "Whereby" }
        if host.contains("jit.si") { return "Jitsi" }
        return "the call"
    }

    private static func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) || host.contains($0) }
    }

    // Scan free text for the first URL that belongs to a meeting provider.
    private static func firstMeetingURL(in text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        var found: URL?
        detector?.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            if let u = match?.url, matches(u) { found = u; stop.pointee = true }
        }
        return found
    }
}
