import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Inserts text at the cursor of the frontmost app: save clipboard, paste, restore.
// Requires the Accessibility permission to post the Cmd+V key event.
enum TextInserter {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // Returns true if the text was pasted, false if it only landed on the clipboard.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard hasAccessibility else { return false }

        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        // Restore the clipboard after the paste lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !savedItems.isEmpty else { return }
            pasteboard.clearContents()
            let restored = savedItems.map { itemData -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in itemData { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        return true
    }
}
