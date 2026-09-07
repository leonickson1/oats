import Foundation

// One-time move from the old "Earshot" identity to "Oats". The app was renamed
// after some people were already on the private beta, so their notes live in
// ~/Library/Application Support/Earshot and their settings live under the old
// bundle id dev.earshot.app. This runs once, before any store reads its folder,
// and brings both across so a rename does not look like a data wipe.
//
// The macOS mic/screen permissions are keyed to the bundle id and cannot be
// migrated; those re-prompt once after the rename (surfaced by the Home banner).
enum DataMigration {
    private static let doneKey = "migratedFromEarshot"
    private static let oldBundleID = "dev.earshot.app"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        migrateDataFolder()
        migrateSettings()

        defaults.set(true, forKey: doneKey)
    }

    // Rename ~/Library/Application Support/Earshot -> Oats (only if the new one
    // does not exist yet, so we never clobber fresh data).
    private static func migrateDataFolder() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = appSupport.appendingPathComponent("Earshot", isDirectory: true)
        let new = appSupport.appendingPathComponent("Oats", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    // Copy the handful of settings that shape the experience out of the old
    // bundle's defaults domain into the current one, so people are not thrown
    // back into onboarding or a reset configuration.
    private static func migrateSettings() {
        guard let old = UserDefaults(suiteName: oldBundleID) else { return }
        let current = UserDefaults.standard
        let keys = [
            "didOnboard", "autoSummary", "autoTitle", "autoEnrich", "hudVisible",
            "transcriptionModelID", "showUpcoming", "perm.systemAudioGranted",
            "autoCheckUpdates", "updateFeedURL", "skippedVersion", "lastUpdateCheck",
            "askSuggestion1", "askSuggestion2",
            "askHotkeyKeyCode", "askHotkeyModifiers", "askHotkeyKeyLabel",
            "demoNoteIDs", "permBannerHidden"
        ]
        for key in keys where old.object(forKey: key) != nil {
            if current.object(forKey: key) == nil {
                current.set(old.object(forKey: key), forKey: key)
            }
        }
    }
}
