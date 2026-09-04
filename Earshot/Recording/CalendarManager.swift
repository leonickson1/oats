import Foundation
import EventKit
import Combine
import AppKit

// Native calendar integration (EventKit): upcoming meetings on Home, and a
// one-click Record that pre-titles the note with the event name.
@MainActor
final class CalendarManager: ObservableObject {
    enum Status: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    @Published private(set) var status: Status = .notDetermined
    @Published private(set) var upcoming: [EKEvent] = []
    @Published var showUpcoming: Bool {
        didSet {
            UserDefaults.standard.set(showUpcoming, forKey: "showUpcoming")
            if showUpcoming { refresh() }
        }
    }

    private let store = EKEventStore()
    private var timer: Timer?

    init() {
        showUpcoming = UserDefaults.standard.object(forKey: "showUpcoming") as? Bool ?? true
        readStatus()
        if status == .authorized { refresh() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func readStatus() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: status = .authorized
        case .notDetermined: status = .notDetermined
        default: status = .denied
        }
    }

    func connect() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            status = granted ? .authorized : .denied
            if granted { refresh() }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        guard status == .authorized else { return }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: 18, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        upcoming = Array(events.prefix(4))
    }
}
