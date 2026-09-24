import Foundation
import AppKit

/// A recordable modifier+key combination (e.g. ⌘⇧R), stored using the
/// same virtual key code and Cocoa modifier-flag bits macOS itself uses, so
/// it can be compared against `com.apple.symbolichotkeys` for conflicts.
struct HotkeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// Raw `NSEvent.ModifierFlags`, limited to `relevantModifiers`.
    var modifiersRaw: UInt

    /// Caps Lock and keypad flags are ignored so they never block a match.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRaw)
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    /// A human-readable form like "⌘⇧R", built from the key code
    /// rather than the event's characters so it stays stable regardless of
    /// which modifiers were held when the combo was recorded.
    var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "\u{2303}" }
        if modifiers.contains(.option) { parts += "\u{2325}" }
        if modifiers.contains(.shift) { parts += "\u{21e7}" }
        if modifiers.contains(.command) { parts += "\u{2318}" }
        parts += Self.keyName(for: keyCode)
        return parts
    }

    private static func keyName(for keyCode: UInt16) -> String {
        Self.keyNamesByCode[keyCode] ?? "Key \(keyCode)"
    }

    /// Covers the keys people realistically pick for a "toggle recording"
    /// shortcut. Not exhaustive — unmapped keys still work, just display
    /// as "Key <code>".
    private static let keyNamesByCode: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        40: "K", 41: ";", 45: "N", 46: "M",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

/// How the user toggles recording. `fnDoubleTap` is the default because it
/// needs no modifier held down and rarely collides with anything else.
enum HotkeyMode: Codable, Equatable, Hashable {
    case fnDoubleTap
    case custom(HotkeyCombo)
    case disabled
}
