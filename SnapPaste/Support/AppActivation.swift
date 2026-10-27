import AppKit

/// Brings SnapPaste to the front when it needs keyboard focus (editor, settings, text window, menu).
///
/// macOS 14's cooperative activation may decline `activate()` for a menu-bar app whose trigger
/// (status item click, Return in the popover) doesn't count as "the user switched to this app".
/// In that case fall back to the older forced activation, which still works for these
/// user-initiated requests.
enum AppActivation {
    static func activate() {
        NSApp.activate()
        if !NSApp.isActive {
            (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
        }
    }
}

/// Calling through a protocol keeps the intentional use of the deprecated API from producing a warning.
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivation {}
