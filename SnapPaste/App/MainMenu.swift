import AppKit

/// Responder-chain actions implemented by the editor canvas. Custom selectors are used for undo/redo
/// so NSWindow's own `undo:` handling never intercepts them.
@objc protocol EditorCommands {
    func snapUndo(_ sender: Any?)
    func snapRedo(_ sender: Any?)
    func copyAndClose(_ sender: Any?)
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
    func zoomToFit(_ sender: Any?)
    func zoomToActualSize(_ sender: Any?)
}

/// SnapPaste is a menu-bar (LSUIElement) app, so this menu is never shown. AppKit still uses its key
/// equivalents, which gives windows standard ⌘C/⌘V/⌘Z/⌘W behavior.
enum MainMenu {
    static func make(target: AppController) -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu(in: main, title: "SnapPaste")
        appMenu.addItem(withTitle: "About SnapPaste", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(AppController.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SnapPaste", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit SnapPaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(EditorCommands.snapUndo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(EditorCommands.snapRedo(_:)), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy and Close", action: #selector(EditorCommands.copyAndClose(_:)), keyEquivalent: "\r")

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Zoom In", action: #selector(EditorCommands.zoomIn(_:)), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: #selector(EditorCommands.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(EditorCommands.zoomToFit(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Actual Size", action: #selector(EditorCommands.zoomToActualSize(_:)), keyEquivalent: "1")

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
