import AppKit
import SnapPasteCore
import SwiftUI

/// Records one shortcut at a time. Key presses are observed only inside SnapPaste's own windows and
/// only while recording; global shortcuts are suspended meanwhile so the current ones can be re-entered.
@Observable
final class ShortcutRecorderModel {
    private(set) var recordingAction: ShortcutAction?
    private(set) var issues: [ShortcutAction: String] = [:]

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let hotkeys: HotkeyManager
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var validator = ShortcutValidator()

    init(settings: SettingsStore, hotkeys: HotkeyManager) {
        self.settings = settings
        self.hotkeys = hotkeys
    }

    func toggleRecording(_ action: ShortcutAction) {
        if recordingAction == action { stop() } else { start(action) }
    }

    func start(_ action: ShortcutAction) {
        stop()
        issues[action] = nil
        validator = ShortcutValidator(systemShortcuts: SystemShortcuts.enabled())
        recordingAction = action
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recordingAction != nil {
            recordingAction = nil
            hotkeys.resume()
        }
    }

    func clear(_ action: ShortcutAction) {
        issues[action] = nil
        settings.shortcuts[action] = nil
    }

    func restoreDefaults() {
        stop()
        issues = [:]
        settings.shortcuts = .defaults
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = KeyModifiers(cocoaFlags: flags.rawValue)
        switch (event.keyCode, modifiers.isEmpty) {
        case (53, true): // Escape cancels
            stop()
            return true
        case (51, true), (117, true): // Delete removes the shortcut
            clear(action)
            stop()
            return true
        default:
            break
        }
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if let issue = validator.issue(for: combo, assigningTo: action, in: settings.shortcuts) {
            issues[action] = issue.message
            NSSound.beep()
            return true
        }
        issues[action] = nil
        settings.shortcuts[action] = combo
        stop()
        return true
    }
}

struct ShortcutField: View {
    let action: ShortcutAction
    let settings: SettingsStore
    let recorder: ShortcutRecorderModel

    private var isRecording: Bool { recorder.recordingAction == action }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recorder.toggleRecording(action)
            } label: {
                Text(label)
                    .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : (settings.shortcuts[action] == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 116)
            }
            .help(isRecording ? "Press the new shortcut. Esc cancels, Delete removes it." : "Click to record a new shortcut")
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(label)

            Button {
                recorder.clear(action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(settings.shortcuts[action] == nil || isRecording ? 0 : 1)
            .disabled(settings.shortcuts[action] == nil || isRecording)
            .help("Remove shortcut")
            .accessibilityLabel("Remove \(action.title) shortcut")
        }
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        return settings.shortcuts[action]?.displayString(keyName: KeyboardLayout.displayName(for:)) ?? "Record Shortcut"
    }
}
