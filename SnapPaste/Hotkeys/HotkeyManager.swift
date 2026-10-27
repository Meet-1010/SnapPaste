import Carbon.HIToolbox
import SnapPasteCore

/// System-wide shortcuts via Carbon's `RegisterEventHotKey`.
///
/// The system delivers an event only when a registered combination is pressed, so there is no
/// polling, no keystroke monitoring, and no Accessibility permission involved.
@Observable
final class HotkeyManager {
    enum Failure: Equatable {
        case inUse
        case failed(OSStatus)

        var message: String {
            switch self {
            case .inUse: "Another app is already using this shortcut."
            case .failed(let status): "macOS refused this shortcut (error \(status))."
            }
        }
    }

    private(set) var failures: [ShortcutAction: Failure] = [:]
    @ObservationIgnored var onAction: ((ShortcutAction) -> Void)?
    @ObservationIgnored private var registered: [ShortcutAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var current = ShortcutConfiguration()
    @ObservationIgnored private var suspended = false

    nonisolated static let signature: OSType = 0x534E_5053 // 'SNPS'

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func apply(_ configuration: ShortcutConfiguration) {
        current = configuration
        guard !suspended else { return }
        registerAll()
    }

    /// Temporarily releases all shortcuts, e.g. while the user records a new one.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }

    private func registerAll() {
        unregisterAll()
        var failures: [ShortcutAction: Failure] = [:]
        for action in ShortcutAction.allCases {
            guard let combo = current[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.rawValue, id, GetApplicationEventTarget(),
                                             OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                failures[action] = status == eventHotKeyExistsErr ? .inUse : .failed(status)
            }
        }
        self.failures = failures
    }

    fileprivate func handle(hotKeyID: UInt32) {
        guard let action = ShortcutAction(hotKeyID: hotKeyID) else { return }
        onAction?(action)
    }
}

private nonisolated func hotKeyEventHandler(_ handler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    let address = UInt(bitPattern: userData)
    // Carbon dispatches application-target events on the main thread.
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue().handle(hotKeyID: id)
    }
    return noErr
}
