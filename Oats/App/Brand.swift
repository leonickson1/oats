import Foundation

// The product name, in one place. The whole app is Oats now, inside and out:
// symbols, bundle id (dev.oats.app), and the on-disk data folder. DataMigration
// moves any old "Earshot" data and settings over on first launch.
enum Brand {
    static let name = "Oats"
    static let tagline = "Meeting notes that never leave your Mac."
}
