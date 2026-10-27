import AppKit
import SwiftUI

/// The menu-bar icon and its popover.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private unowned let controller: AppController
    private var performedAction = false
    private let menuState = MenuPopoverState()

    init(controller: AppController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapPaste")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SnapPaste"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let hosting = NSHostingController(rootView: MenuPopoverView(controller: controller, state: menuState, dismiss: { [weak self] in
            self?.performedAction = true
            self?.close()
        }))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    @objc private func togglePopover(_ sender: Any?) {
        toggle()
    }

    func toggle() {
        popover.isShown ? close() : show()
    }

    func show() {
        guard let button = statusItem.button, !popover.isShown else { return }
        controller.rememberFrontmostApp()
        controller.permission.refresh()
        performedAction = false
        menuState.highlighted = nil
        // Activate so the popover takes keyboard focus (arrow keys / Return / Escape).
        AppActivation.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if !performedAction {
            controller.restoreFocusIfIdle()
        }
    }
}
