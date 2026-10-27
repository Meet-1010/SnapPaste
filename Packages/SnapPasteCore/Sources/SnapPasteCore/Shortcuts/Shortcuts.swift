import Foundation

public enum ShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case openMenu
    case captureRegion
    case captureWindow
    case captureScreen
    case copyLastCapture
    case openEditor
    case extractText

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openMenu: "Open SnapPaste"
        case .captureRegion: "Capture Region"
        case .captureWindow: "Capture Window"
        case .captureScreen: "Capture Entire Screen"
        case .copyLastCapture: "Copy Last Capture"
        case .openEditor: "Open Editor"
        case .extractText: "Extract Text"
        }
    }

    /// Stable numeric ID for Carbon hot key registration.
    public var hotKeyID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)! + 1)
    }

    public init?(hotKeyID: UInt32) {
        let index = Int(hotKeyID) - 1
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }

    /// Control-Shift combos: unused by macOS's own shortcuts and rarely claimed by apps.
    /// The digits mirror the system screenshot keys (⌘⇧3/4/5) without colliding with them.
    public var defaultCombo: KeyCombo {
        let ctrlShift: KeyModifiers = [.control, .shift]
        switch self {
        case .openMenu: return KeyCombo(keyCode: 1, modifiers: ctrlShift)         // ⌃⇧S
        case .captureRegion: return KeyCombo(keyCode: 21, modifiers: ctrlShift)   // ⌃⇧4
        case .captureWindow: return KeyCombo(keyCode: 23, modifiers: ctrlShift)   // ⌃⇧5
        case .captureScreen: return KeyCombo(keyCode: 20, modifiers: ctrlShift)   // ⌃⇧3
        case .copyLastCapture: return KeyCombo(keyCode: 8, modifiers: ctrlShift)  // ⌃⇧C
        case .openEditor: return KeyCombo(keyCode: 14, modifiers: ctrlShift)      // ⌃⇧E
        case .extractText: return KeyCombo(keyCode: 17, modifiers: ctrlShift)     // ⌃⇧T
        }
    }
}

/// Which combo (if any) triggers each action.
public struct ShortcutConfiguration: Equatable, Sendable, Codable {
    private var bindings: [ShortcutAction: KeyCombo]

    public static var defaults: ShortcutConfiguration {
        var bindings: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases { bindings[action] = action.defaultCombo }
        return ShortcutConfiguration(bindings: bindings)
    }

    public init(bindings: [ShortcutAction: KeyCombo] = [:]) {
        self.bindings = bindings
    }

    public subscript(action: ShortcutAction) -> KeyCombo? {
        get { bindings[action] }
        set { bindings[action] = newValue }
    }

    public func action(for combo: KeyCombo) -> ShortcutAction? {
        ShortcutAction.allCases.first { bindings[$0] == combo }
    }

    // Encoded as {"captureRegion": {...}, "openMenu": null}. A missing key means "use the default",
    // so actions added in later versions get their defaults while explicitly cleared ones stay cleared.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode([String: KeyCombo?].self)
        var bindings: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases {
            if let entry = stored[action.rawValue] {
                if let combo = entry { bindings[action] = combo }
            } else {
                bindings[action] = action.defaultCombo
            }
        }
        self.bindings = bindings
    }

    public func encode(to encoder: Encoder) throws {
        var stored: [String: KeyCombo?] = [:]
        for action in ShortcutAction.allCases { stored[action.rawValue] = .some(bindings[action]) }
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}

public enum ShortcutIssue: Error, Equatable, Sendable {
    case modifierOnly
    case needsCommandOrControl
    case reservedStandardShortcut
    case conflictsWithSystem
    case duplicate(ShortcutAction)

    public var message: String {
        switch self {
        case .modifierOnly: "Press a key together with the modifiers."
        case .needsCommandOrControl: "Global shortcuts must include ⌘ or ⌃."
        case .reservedStandardShortcut: "⌘ plus a single key is used by apps (⌘C, ⌘V, …). Add ⌃, ⌥ or ⇧."
        case .conflictsWithSystem: "macOS already uses this shortcut. Choose another one or turn it off in System Settings › Keyboard › Keyboard Shortcuts."
        case .duplicate(let action): "Already used for “\(action.title)”."
        }
    }
}

public struct ShortcutValidator: Sendable {
    /// Enabled system-wide shortcuts (from the symbolic hot key table).
    public var systemShortcuts: Set<KeyCombo>

    public init(systemShortcuts: Set<KeyCombo> = []) {
        self.systemShortcuts = systemShortcuts
    }

    public func issue(for combo: KeyCombo, assigningTo action: ShortcutAction, in configuration: ShortcutConfiguration) -> ShortcutIssue? {
        if combo.isModifierOnly { return .modifierOnly }
        // Since macOS 15, hot keys registered with only ⌥ or ⌥⇧ are ignored, and keys without
        // modifiers would swallow normal typing.
        if !combo.modifiers.contains(.command) && !combo.modifiers.contains(.control) { return .needsCommandOrControl }
        if combo.modifiers == [.command] { return .reservedStandardShortcut }
        if systemShortcuts.contains(combo) { return .conflictsWithSystem }
        if let other = configuration.action(for: combo), other != action { return .duplicate(other) }
        return nil
    }
}
