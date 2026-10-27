import Foundation

/// Modifier keys using Carbon's bit layout, which `RegisterEventHotKey` expects.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & Self.carbonMask
    }

    public static let command = KeyModifiers(rawValue: 1 << 8)   // cmdKey
    public static let shift = KeyModifiers(rawValue: 1 << 9)     // shiftKey
    public static let option = KeyModifiers(rawValue: 1 << 11)   // optionKey
    public static let control = KeyModifiers(rawValue: 1 << 12)  // controlKey

    static let carbonMask: UInt32 = (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)

    /// Converts `NSEvent.ModifierFlags.rawValue`.
    public init(cocoaFlags: UInt) {
        var m: KeyModifiers = []
        if cocoaFlags & (1 << 17) != 0 { m.insert(.shift) }
        if cocoaFlags & (1 << 18) != 0 { m.insert(.control) }
        if cocoaFlags & (1 << 19) != 0 { m.insert(.option) }
        if cocoaFlags & (1 << 20) != 0 { m.insert(.command) }
        self = m
    }

    public var cocoaFlags: UInt {
        var flags: UInt = 0
        if contains(.shift) { flags |= 1 << 17 }
        if contains(.control) { flags |= 1 << 18 }
        if contains(.option) { flags |= 1 << 19 }
        if contains(.command) { flags |= 1 << 20 }
        return flags
    }

    /// Symbols in Apple's canonical order: ⌃⌥⇧⌘.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key plus modifiers. `keyCode` is a hardware virtual key code (kVK_*), independent of layout.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers

    public init(keyCode: UInt32, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public func displayString(keyName: (UInt32) -> String = KeyNames.name(for:)) -> String {
        modifiers.symbols + keyName(keyCode)
    }

    public var isModifierOnly: Bool { KeyNames.modifierKeyCodes.contains(keyCode) }
}

/// Names for virtual key codes on an ANSI (US) layout, used for display and as a fallback.
public enum KeyNames {
    public static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func name(for keyCode: UInt32) -> String {
        special[keyCode] ?? characters[keyCode] ?? "Key \(keyCode)"
    }

    /// Names for keys whose label doesn't come from the keyboard layout.
    public static func specialName(for keyCode: UInt32) -> String? {
        special[keyCode]
    }

    static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static let characters: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]
}
