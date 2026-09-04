import Foundation
import Carbon.HIToolbox

// Global hotkeys via Carbon (reliable, consumable, no Accessibility needed):
//   Opt+M  new meeting note (or open the live one)
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onNewNote: (() -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    private init() {}

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
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &handlerRef
        )

        let signature = OSType(0x4541_5253) // "EARS"
        var newNoteRef: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(optionKey),
            EventHotKeyID(signature: signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &newNoteRef
        )
        hotKeyRefs = [newNoteRef]
    }
}
