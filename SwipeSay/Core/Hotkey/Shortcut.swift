import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut stored with Carbon key code + modifiers.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let defaultSelection = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(optionKey), keyLabel: "D")
    static let defaultScreenshot = Shortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(optionKey), keyLabel: "S")
    static let defaultInput = Shortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey), keyLabel: "A")

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// Builds a shortcut from a key-down event. Requires at least one of ⌘ ⌥ ⌃.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = mods
        self.keyLabel = Shortcut.label(for: Int(event.keyCode), event: event)
    }

    private static func label(for keyCode: Int, event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[keyCode] { return s }
        // Use the layout-independent character where possible.
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
           let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0x7F {
            return chars.uppercased()
        }
        return "#\(keyCode)"
    }
}
