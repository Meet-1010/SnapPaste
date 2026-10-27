import AppKit
import SnapPasteCore

/// Coordinates capture, clipboard, editor, OCR and settings. Owns all long-lived app state.
@Observable
final class AppController: NSObject {
    let settings: SettingsStore
    let captureStore = CaptureStore()
    let hotkeys = HotkeyManager()
    let permission = ScreenRecordingPermission()

    /// Small preview of the capture currently held in memory (nil when nothing is held).
    private(set) var lastCaptureThumbnail: NSImage?

    @ObservationIgnored private let capture: CaptureCoordinator
    @ObservationIgnored private let clipboard = ClipboardService()
    @ObservationIgnored private let hud = HUDController()
    @ObservationIgnored private var statusItem: StatusItemController?
    @ObservationIgnored private var editorController: EditorWindowController?
    @ObservationIgnored private var ocrController: OCRWindowController?
    @ObservationIgnored private var settingsController: SettingsWindowController?
    @ObservationIgnored private var permissionController: PermissionWindowController?
    @ObservationIgnored private var autoClearTask: Task<Void, Never>?

    override init() {
        settings = SettingsStore()
        capture = CaptureCoordinator(permission: permission)
        super.init()
    }

    func start() {
        statusItem = StatusItemController(controller: self)
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.apply(settings.shortcuts)
        settings.onShortcutsChanged = { [weak self] configuration in
            self?.hotkeys.apply(configuration)
        }
    }

    func shutdown() {
        autoClearTask?.cancel()
        hotkeys.unregisterAll()
        editorController?.closeSilently()
        ocrController?.close()
        captureStore.clear()
        lastCaptureThumbnail = nil
    }

    // MARK: - Actions

    func perform(_ action: ShortcutAction) {
        switch action {
        case .openMenu: toggleMenu()
        case .captureRegion: startCapture(.region)
        case .captureWindow: startCapture(.window)
        case .captureScreen: startCapture(.screen(nil))
        case .copyLastCapture: copyLastCapture()
        case .openEditor: openEditorForLastCapture()
        case .extractText: extractTextFromRegion()
        }
    }

    func showMenu() { statusItem?.show() }
    func toggleMenu() { statusItem?.toggle() }

    func shortcutLabel(for action: ShortcutAction) -> String? {
        settings.shortcuts[action].map { $0.displayString(keyName: KeyboardLayout.displayName(for:)) }
    }

    // MARK: - Capture

    func startCapture(_ kind: CaptureCoordinator.Kind) {
        let fromMenu = statusItem?.isShown ?? false
        statusItem?.close()
        Task {
            if fromMenu {
                // Give focus back to the app the user was in so window captures show it as active.
                restoreFocusIfIdle()
                try? await Task.sleep(for: .milliseconds(150))
            }
            switch await capture.capture(kind) {
            case .success(let image): handleCapture(image)
            case .failure(let failure): handle(failure)
            }
        }
    }

    private func handleCapture(_ image: CGImage) {
        // A new capture replaces the previous one, including any open editing session.
        editorController?.closeSilently()
        editorController = nil
        let document = captureStore.replace(with: image)
        updateThumbnail()

        let action = PostCaptureAction.resolve(quickCopy: settings.quickCopy, openEditorAfterCapture: settings.openEditorAfterCapture)
        if action.copiesImmediately {
            Task { await copy(document) }
        }
        if action.opensEditor {
            openEditor(for: document)
        } else {
            scheduleAutoClear()
        }
    }

    private func handle(_ failure: CaptureFailure) {
        switch failure {
        case .cancelled, .alreadyCapturing:
            return
        case .permissionDenied:
            showPermissionHelp()
        default:
            hud.show(failure.message, symbol: "exclamationmark.triangle.fill", style: .warning)
        }
    }

    // MARK: - Clipboard

    @discardableResult
    func copy(_ document: EditorDocument) async -> Bool {
        let size = document.pixelSize
        switch await clipboard.copy(image: document.image, annotations: document.annotations) {
        case .copied:
            if settings.showCopyConfirmation {
                hud.show("Copied to Clipboard", detail: "\(size) px", symbol: "doc.on.clipboard.fill")
            }
            return true
        case .superseded:
            return true
        case .failed:
            hud.show("Couldn't copy the image", symbol: "exclamationmark.triangle.fill", style: .warning)
            return false
        }
    }

    func copyLastCapture() {
        statusItem?.close()
        guard let document = captureStore.document else {
            hud.show("Nothing captured yet", detail: captureHint(), symbol: "camera.viewfinder")
            return
        }
        Task { await copy(document) }
    }

    func copyText(_ text: String) {
        clipboard.copyText(text)
        if settings.showCopyConfirmation {
            hud.show("Text Copied", detail: "\(text.count) characters", symbol: "doc.on.clipboard.fill")
        }
    }

    // MARK: - Editor

    func openEditorForLastCapture() {
        statusItem?.close()
        guard let document = captureStore.document else {
            hud.show("Nothing captured yet", detail: captureHint(), symbol: "camera.viewfinder")
            return
        }
        openEditor(for: document)
    }

    private func openEditor(for document: EditorDocument) {
        cancelAutoClear()
        if let existing = editorController, existing.editorDocument === document {
            AppActivation.activate()
            existing.showWindow(nil)
            return
        }
        editorController?.closeSilently()
        rememberFrontmostApp()
        let controller = EditorWindowController(
            document: document,
            settings: settings,
            actions: EditorActions(
                copy: { [weak self] document in await self?.copy(document) ?? false },
                extractText: { [weak self] document in self?.extractText(from: document) },
                closed: { [weak self] restoreFocus in self?.editorDidClose(restoreFocus: restoreFocus) }
            )
        )
        editorController = controller
        AppActivation.activate()
        controller.showWindow(nil)
    }

    #if DEBUG
    func openEditorForTesting(_ document: EditorDocument) {
        updateThumbnail()
        openEditor(for: document)
    }
    #endif

    private func editorDidClose(restoreFocus: Bool) {
        editorController = nil
        updateThumbnail()
        scheduleAutoClear()
        if restoreFocus { restoreFocusIfIdle() }
    }

    // MARK: - Text recognition

    func extractTextFromRegion() {
        statusItem?.close()
        Task {
            switch await capture.capture(.region) {
            case .success(let image):
                // Region OCR never becomes the "last capture" and never touches the image clipboard.
                showTextRecognition(for: image, source: "Selected region")
            case .failure(let failure):
                handle(failure)
            }
        }
    }

    func extractTextFromLastCapture() {
        statusItem?.close()
        guard let document = captureStore.document else {
            hud.show("Nothing captured yet", detail: captureHint(), symbol: "camera.viewfinder")
            return
        }
        extractText(from: document)
    }

    private func extractText(from document: EditorDocument) {
        let includeAnnotations = settings.ocrIncludesAnnotations && !document.annotations.isEmpty
        let image = includeAnnotations ? (document.renderedImage() ?? document.image) : document.image
        showTextRecognition(for: image, source: includeAnnotations ? "Capture with annotations" : "Capture")
    }

    private func showTextRecognition(for image: CGImage, source: String) {
        if !hasVisibleWindows { rememberFrontmostApp() }
        let controller = ocrController ?? OCRWindowController(
            onCopy: { [weak self] text in self?.copyText(text) },
            onClose: { [weak self] in self?.restoreFocusIfIdle() }
        )
        ocrController = controller
        AppActivation.activate()
        controller.recognize(image, source: source, recognizer: TextRecognizer(languages: settings.ocrLanguages))
    }

    // MARK: - Memory

    func clearCapture() {
        cancelAutoClear()
        editorController?.closeSilently()
        editorController = nil
        captureStore.clear()
        lastCaptureThumbnail = nil
    }

    private func updateThumbnail() {
        guard let image = captureStore.document?.image,
              let thumbnail = ImageRenderer.thumbnail(of: image, maxPixelSize: 480) else {
            lastCaptureThumbnail = nil
            return
        }
        lastCaptureThumbnail = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width / 2, height: thumbnail.height / 2))
    }

    private func scheduleAutoClear() {
        autoClearTask?.cancel()
        guard let minutes = settings.clearCaptureAfter.minutes, captureStore.hasCapture, editorController == nil else { return }
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.clearCapture()
        }
    }

    private func cancelAutoClear() {
        autoClearTask?.cancel()
        autoClearTask = nil
    }

    func settingsDidChangeAutoClear() {
        if editorController == nil { scheduleAutoClear() }
    }

    // MARK: - Windows and focus

    @objc func showSettings(_ sender: Any?) {
        statusItem?.close()
        if !hasVisibleWindows { rememberFrontmostApp() }
        let controller = settingsController ?? SettingsWindowController(
            controller: self,
            onClose: { [weak self] in self?.restoreFocusIfIdle() }
        )
        settingsController = controller
        AppActivation.activate()
        controller.show()
    }

    func showPermissionHelp() {
        statusItem?.close()
        if !hasVisibleWindows { rememberFrontmostApp() }
        let controller = permissionController ?? PermissionWindowController(
            permission: permission,
            onClose: { [weak self] in self?.restoreFocusIfIdle() }
        )
        permissionController = controller
        AppActivation.activate()
        controller.show()
    }

    @ObservationIgnored private var previousApp: NSRunningApplication?

    func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current {
            previousApp = app
        }
    }

    private var hasVisibleWindows: Bool {
        NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
    }

    /// When SnapPaste has nothing left on screen, hand focus back to the app the user came from,
    /// so ⌘V lands there right away.
    func restoreFocusIfIdle() {
        guard !hasVisibleWindows, NSApp.isActive else { return }
        if let app = previousApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    private func captureHint() -> String? {
        shortcutLabel(for: .captureRegion).map { "Press \($0) to capture a region." }
    }
}
