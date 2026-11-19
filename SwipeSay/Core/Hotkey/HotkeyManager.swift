import AppKit
import SwipeSayKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys through Carbon (works without extra permissions).
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Action: UInt32, CaseIterable {
        case selection = 1
        case screenshot = 2
        case input = 3
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false

    func register(_ action: Action, shortcut: Shortcut, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregisterRef(action.rawValue)
        handlers[action.rawValue] = handler
        shortcuts[action.rawValue] = shortcut
        if !suspended { registerRef(action.rawValue) }
    }

    /// Temporarily removes all hotkeys (e.g. while recording a new shortcut).
    func suspend() {
        suspended = true
        for id in refs.keys { unregisterRef(id) }
    }

    func resume() {
        suspended = false
        for id in shortcuts.keys { registerRef(id) }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func registerRef(_ id: UInt32) {
        guard let shortcut = shortcuts[id], refs[id] == nil else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5357_5359), id: id) // "SWSY"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
        } else {
            NSLog("SwipeSay: failed to register hotkey \(shortcut.displayString) (\(status))")
        }
    }

    private func unregisterRef(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
