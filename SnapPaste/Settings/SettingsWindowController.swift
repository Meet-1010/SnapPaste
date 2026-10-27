import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private let recorder: ShortcutRecorderModel

    init(controller: AppController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        recorder = ShortcutRecorderModel(settings: controller.settings, hotkeys: controller.hotkeys)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "SnapPaste Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        let hosting = NSHostingController(rootView: SettingsView(controller: controller, recorder: recorder))
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stop()
        DispatchQueue.main.async { [onClose] in onClose() }
    }
}
