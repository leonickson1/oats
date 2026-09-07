import Foundation
import Carbon.HIToolbox
import AppKit

// Global hotkeys via Carbon (reliable, consumable, no Accessibility needed):
//   Opt+M      new meeting note (or open the live one)
//   <summon>   Ask popup, user-configurable (default Opt+Space, with Cmd+Opt+Space
//              as a fallback while the default is in use)
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onNewNote: (() -> Void)?
    var onAsk: (() -> Void)?

    private var newNoteRef: EventHotKeyRef?
    private var askRef: EventHotKeyRef?
    private var askFallbackRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature = OSType(0x4541_5253) // "EARS"

    private init() {}

    // MARK: - Configurable Ask shortcut

    static let defaultAskKeyCode = kVK_Space
    static let defaultAskModifiers = optionKey

    static var askKeyCode: Int { UserDefaults.standard.object(forKey: "askHotkeyKeyCode") as? Int ?? defaultAskKeyCode }
    static var askModifiers: Int { UserDefaults.standard.object(forKey: "askHotkeyModifiers") as? Int ?? defaultAskModifiers }
    static var askLabel: String { UserDefaults.standard.string(forKey: "askHotkeyKeyLabel") ?? "Space" }
    static var isAskDefault: Bool { askKeyCode == defaultAskKeyCode && askModifiers == defaultAskModifiers }
    static var askDisplay: String { modifierSymbols(askModifiers) + askLabel }

    // Carbon modifier bitmask -> menu-style symbols, in canonical order.
    static func modifierSymbols(_ carbon: Int) -> String {
        var s = ""
        if carbon & controlKey != 0 { s += "⌃" }
        if carbon & optionKey != 0 { s += "⌥" }
        if carbon & shiftKey != 0 { s += "⇧" }
        if carbon & cmdKey != 0 { s += "⌘" }
        return s
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var c = 0
        if flags.contains(.command) { c |= cmdKey }
        if flags.contains(.option) { c |= optionKey }
        if flags.contains(.control) { c |= controlKey }
        if flags.contains(.shift) { c |= shiftKey }
        return c
    }

    // MARK: - Registration

    func register() {
        guard handlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    if id == 1 { HotkeyManager.shared.onNewNote?() }
                    else { HotkeyManager.shared.onAsk?() }
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &handlerRef
        )

        newNoteRef = add(keyCode: kVK_ANSI_M, modifiers: optionKey, id: 1)
        registerAsk()
    }

    // Re-registers just the Ask shortcut; call after the user changes it.
    func reloadAskHotkey() {
        registerAsk()
    }

    private func registerAsk() {
        if let askRef { UnregisterEventHotKey(askRef); self.askRef = nil }
        if let askFallbackRef { UnregisterEventHotKey(askFallbackRef); self.askFallbackRef = nil }
        askRef = add(keyCode: Self.askKeyCode, modifiers: Self.askModifiers, id: 2)
        // Keep the Cmd+Opt+Space fallback only while the user is on the default combo.
        if Self.isAskDefault {
            askFallbackRef = add(keyCode: kVK_Space, modifiers: optionKey | cmdKey, id: 3)
        }
    }

    private func add(keyCode: Int, modifiers: Int, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        return ref
    }
}
