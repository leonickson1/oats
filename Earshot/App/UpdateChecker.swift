import SwiftUI
import AppKit

// A lightweight, self-contained update checker. It fetches a small JSON manifest
// (the "appcast") describing the latest version, compares it to what is running,
// and offers to open the download. No third-party framework; when we want silent
// auto-install later, this is the seam to swap in Sparkle.
struct UpdateInfo: Codable, Equatable {
    let version: String
    let notes: String
    let url: String
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var available: UpdateInfo?
    @Published var checking = false
    @Published var lastResult: String?
    @Published var showSheet = false

    // Point this at your hosted appcast.json (e.g. a GitHub raw URL or release).
    @AppStorage("updateFeedURL") var feedURL = "https://raw.githubusercontent.com/earshot-app/earshot/main/appcast.json"
    @AppStorage("autoCheckUpdates") var autoCheck = true

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // Called on launch: checks at most once a day, quietly.
    func checkOnLaunchIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        guard now - last > 60 * 60 * 24 else { return }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        checking = true
        defer { checking = false }
        guard let url = URL(string: feedURL) else {
            lastResult = "The update URL is not set."
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            if isNewer(info.version, than: currentVersion) {
                available = info
                lastResult = "Update available: \(info.version)."
                let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                if userInitiated || skipped != info.version {
                    AppState.shared.showMainWindow()
                    showSheet = true
                }
            } else {
                available = nil
                lastResult = "You're up to date (\(currentVersion))."
            }
        } catch {
            available = nil
            lastResult = userInitiated ? "Could not check for updates right now." : nil
        }
    }

    func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    func skip() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "skippedVersion") }
        showSheet = false
        available = nil
    }

    func remindLater() { showSheet = false }

    func install() {
        if let u = available.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(u) }
        showSheet = false
    }
}

// The update prompt, styled like a standard Mac software-update dialog.
struct UpdateSheet: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let info = checker.available {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    EarshotTileLogoView(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A new version of Oats is available!")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Oats \(info.version) is now available, you have \(checker.currentVersion). Would you like to get it now?")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !info.notes.isEmpty {
                    Text("Release notes")
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        Text(info.notes)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack {
                    Button("Skip This Version") { checker.skip() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Remind Me Later") { checker.remindLater() }
                        .buttonStyle(.bordered)
                    Button("Install Update") { checker.install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 470)
        }
    }
}

// Settings card: auto-check toggle, manual check, current version.
struct UpdatesCard: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        SettingsCard(
            icon: "arrow.triangle.2.circlepath",
            title: "Updates",
            explainer: "Oats can check for new versions and let you install them. The check is a small download of a version file; nothing else leaves your Mac."
        ) {
            HStack {
                Text("Automatically check for updates")
                    .font(.system(size: 13))
                Spacer()
                Toggle("", isOn: $checker.autoCheck)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Button(checker.checking ? "Checking…" : "Check now") {
                    Task { await checker.check(userInitiated: true) }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(checker.checking)
                Text(checker.lastResult ?? "Version \(checker.currentVersion)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        }
    }
}
