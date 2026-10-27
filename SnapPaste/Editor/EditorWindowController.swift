import AppKit
import SnapPasteCore
import SwiftUI

struct EditorActions {
    let copy: (EditorDocument) async -> Bool
    let extractText: (EditorDocument) -> Void
    let closed: (_ restoreFocus: Bool) -> Void
}

/// Weak handle the SwiftUI views use to reach the controller without creating a retain cycle
/// (window → hosting view → view → controller → window).
struct EditorCommandProxy {
    weak var controller: EditorWindowController?

    func copy() { controller?.copyToClipboard() }
    func copyAndClose() { controller?.copyAndClose() }
    func cancel() { controller?.cancel() }
    func extractText() { controller?.extractText() }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    let session: EditorSession
    private let actions: EditorActions
    private var notifiesOnClose = true
    private var isCopying = false

    init(document: EditorDocument, settings: SettingsStore, actions: EditorActions) {
        self.editorDocument = document
        self.actions = actions
        session = EditorSession(document: document, settings: settings)
        let window = NSWindow(
            contentRect: Self.initialContentRect(for: document.pixelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapPaste Editor"
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        session.controller = self
        window.contentView = NSHostingView(rootView: EditorView(session: session, commands: EditorCommandProxy(controller: self)))
        window.delegate = self
        window.center()
        updateSubtitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens at the capture's on-screen size when it fits, otherwise at most 85% of the screen.
    private static func initialContentRect(for size: PixelSize) -> NSRect {
        let screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        let chrome = NSSize(width: 64, height: 170)
        let width = min(max(CGFloat(size.width) / scale + chrome.width, 820), visible.width * 0.85)
        let height = min(max(CGFloat(size.height) / scale + chrome.height, 480), visible.height * 0.85)
        return NSRect(x: 0, y: 0, width: width, height: height)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        if let canvas = session.canvas { window?.makeFirstResponder(canvas) }
    }

    func documentDidChange() {
        updateSubtitle()
    }

    private func updateSubtitle() {
        let count = editorDocument.annotations.count
        let annotations = count == 0 ? "" : count == 1 ? " · 1 annotation" : " · \(count) annotations"
        window?.subtitle = "\(editorDocument.pixelSize.description) px\(annotations)"
    }

    // MARK: Actions

    func copyToClipboard() {
        session.canvas?.commitTextEditing()
        Task { _ = await actions.copy(editorDocument) }
    }

    func copyAndClose() {
        guard !isCopying else { return }
        session.canvas?.commitTextEditing()
        isCopying = true
        Task {
            let copied = await actions.copy(editorDocument)
            isCopying = false
            if copied { close() }
        }
    }

    /// Closes without touching the clipboard. Edits stay with the capture in memory.
    func cancel() {
        close()
    }

    func extractText() {
        session.canvas?.commitTextEditing()
        actions.extractText(editorDocument)
    }

    /// Closes because a newer capture replaced this one; the app controller already knows.
    func closeSilently() {
        notifiesOnClose = false
        close()
    }

    func windowWillClose(_ notification: Notification) {
        session.canvas?.tearDown()
        let notify = notifiesOnClose
        DispatchQueue.main.async { [weak self, actions] in
            // Drop the view tree so the canvas and its image layer are released immediately.
            self?.window?.contentView = nil
            if notify { actions.closed(true) }
        }
    }
}
