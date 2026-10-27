import AppKit
import SnapPasteCore

/// The editing surface.
///
/// The screenshot is shown by a layer (GPU-scaled, never redrawn on the CPU while editing). Committed
/// annotations, the annotation being drawn, and editor chrome (selection, crop, eraser ring) each
/// live in their own transparent view, so a pointer drag only redraws the stroke being made.
final class EditorCanvasView: NSView, EditorCommands, NSMenuItemValidation, NSTextFieldDelegate {
    private let session: EditorSession
    private var document: EditorDocument { session.document }

    private let imageView = ImageLayerView()
    private let annotationsView = DrawingView()
    private let liveView = DrawingView()
    private let chromeView = DrawingView()

    private(set) var viewport = ViewportTransform.identity
    private var fitsWindow = true
    private static let padding: CGFloat = 24

    private enum Interaction {
        case none
        case drawing(Annotation, start: CGPoint)
        case moving(original: Annotation, start: CGPoint, current: Annotation)
        case cropping(start: CGPoint)
        case movingCrop(original: CGRect, start: CGPoint)
        case erasing(Set<UUID>)
        case panning(start: CGPoint, offset: CGPoint)
    }

    private var interaction: Interaction = .none
    /// Annotations temporarily drawn elsewhere (being moved, edited, or erased).
    private var hiddenIDs: Set<UUID> = []
    private var lastLiveRect: CGRect = .null
    private var mouseLocation: CGPoint?
    private var spaceHeld = false

    private struct EditingText {
        let field: NSTextField
        let origin: CGPoint
        var fontSize: CGFloat
        var color: RGBAColor
        let existingID: UUID?
    }
    private var editingText: EditingText?

    init(session: EditorSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        for view in [imageView, annotationsView, liveView, chromeView] as [NSView] {
            addSubview(view)
        }
        imageView.image = session.document.image
        annotationsView.drawHandler = { [unowned self] context in drawAnnotations(in: context) }
        liveView.drawHandler = { [unowned self] context in drawLive(in: context) }
        chromeView.drawHandler = { [unowned self] context in drawChrome(in: context) }
        session.document.onChange = { [weak self] in self?.documentDidChange() }
        session.canvas = self
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot editing canvas")
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Releases references so the image and annotations can be freed as soon as the window closes.
    func tearDown() {
        commitTextEditing()
        session.document.onChange = nil
        imageView.image = nil
        annotationsView.drawHandler = nil
        liveView.drawHandler = nil
        chromeView.drawHandler = nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout and viewport

    private var imageSize: CGSize { document.pixelSize.cgSize }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        for view in [annotationsView, liveView, chromeView] { view.frame = bounds }
        if fitsWindow {
            viewport = fittedViewport()
        } else {
            viewport = viewport.clamped(imageSize: imageSize, viewSize: bounds.size, padding: Self.padding)
        }
        applyViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI creates the canvas after the window is shown; take keyboard focus so tool keys,
        // Escape and ⌘Z work without clicking first.
        if let window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        }
    }

    /// Fit inside the window, never enlarging past one image pixel per screen pixel.
    private func fittedViewport() -> ViewportTransform {
        .fit(imageSize: imageSize, in: bounds.size, padding: Self.padding, maxZoom: 1 / backingScale)
    }

    private func applyViewport() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = viewport.imageToView(CGRect(origin: .zero, size: imageSize))
        imageView.updateFilters(devicePixelsPerImagePixel: viewport.zoom * backingScale)
        CATransaction.commit()
        annotationsView.needsDisplay = true
        liveView.needsDisplay = true
        chromeView.needsDisplay = true
        lastLiveRect = .null
        layoutTextField()
        let percent = Int((viewport.zoom * backingScale * 100).rounded())
        if session.zoomPercent != percent { session.zoomPercent = percent }
    }

    private func setZoom(_ zoom: CGFloat, anchor: CGPoint? = nil) {
        fitsWindow = false
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        viewport = viewport.zoomed(to: zoom, anchor: anchor).clamped(imageSize: imageSize, viewSize: bounds.size, padding: Self.padding)
        applyViewport()
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(viewport.zoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setZoom(viewport.zoom / 1.25) }

    @objc func zoomToFit(_ sender: Any?) {
        fitsWindow = true
        viewport = fittedViewport()
        applyViewport()
    }

    @objc func zoomToActualSize(_ sender: Any?) { setZoom(1 / backingScale) }

    override func magnify(with event: NSEvent) {
        setZoom(viewport.zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if event.modifierFlags.contains(.command) {
            let factor = pow(1.005, event.scrollingDeltaY * multiplier)
            setZoom(viewport.zoom * factor, anchor: convert(event.locationInWindow, from: nil))
            return
        }
        fitsWindow = false
        var next = viewport
        next.offset.x += event.scrollingDeltaX * multiplier
        next.offset.y += event.scrollingDeltaY * multiplier
        viewport = next.clamped(imageSize: imageSize, viewSize: bounds.size, padding: Self.padding)
        applyViewport()
    }

    // MARK: - Document and session changes

    private func documentDidChange() {
        if imageView.image !== document.image {
            imageView.image = document.image
            fitsWindow = true
            needsLayout = true
        }
        if let id = session.selectedID, document.annotation(withID: id) == nil {
            session.selectedID = nil
        }
        hiddenIDs = hiddenIDs.filter { id in editingText?.existingID == id }
        annotationsView.needsDisplay = true
        chromeView.needsDisplay = true
        session.controller?.documentDidChange()
    }

    func toolDidChange(from oldTool: EditorTool) {
        commitTextEditing()
        interaction = .none
        if oldTool == .crop { session.cropRect = nil }
        if session.tool != .select && session.tool != .text { session.selectedID = nil }
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(self)
        liveView.needsDisplay = true
        chromeView.needsDisplay = true
    }

    func selectionDidChange() {
        if let selected = session.selectedAnnotation { session.adoptStyle(of: selected) }
        chromeView.needsDisplay = true
    }

    func styleDidChange() {
        guard var editing = editingText else { return }
        editing.color = session.color
        editing.fontSize = session.fontSize
        editingText = editing
        editing.field.textColor = NSColor(cgColor: editing.color.cgColor)
        layoutTextField()
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        if spaceHeld {
            cursor = .openHand
        } else {
            switch session.tool {
            case .select: cursor = .arrow
            case .text: cursor = .iBeam
            case .eraser: cursor = .crosshair
            default: cursor = .crosshair
            }
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if session.tool == .eraser { chromeView.needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        if session.tool == .eraser { chromeView.needsDisplay = true }
    }

    // MARK: - Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        viewport.viewToImage(convert(event.locationInWindow, from: nil))
    }

    /// Hit tolerance of a few screen points, expressed in image pixels.
    private var tolerance: CGFloat { 5 / viewport.zoom }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), imageSize.width), y: min(max(0, p.y), imageSize.height))
    }

    private func topAnnotation(at p: CGPoint, includeInterior: Bool, where predicate: (Annotation) -> Bool = { _ in true }) -> Annotation? {
        document.annotations.last { !hiddenIDs.contains($0.id) && predicate($0) && $0.hitTest(p, tolerance: tolerance, includeInterior: includeInterior) }
    }

    override func mouseDown(with event: NSEvent) {
        if editingText != nil {
            // A click outside the text box finishes typing; it doesn't start a new action.
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if spaceHeld || event.buttonNumber == 2 {
            interaction = .panning(start: viewPoint, offset: viewport.offset)
            NSCursor.closedHand.set()
            return
        }
        let p = viewport.viewToImage(viewPoint)

        switch session.tool {
        case .select:
            if let hit = topAnnotation(at: p, includeInterior: true) {
                session.selectedID = hit.id
                if event.clickCount >= 2, hit.isText {
                    beginEditingText(hit)
                } else {
                    interaction = .moving(original: hit, start: p, current: hit)
                }
            } else {
                session.selectedID = nil
            }

        case .text:
            if let hit = topAnnotation(at: p, includeInterior: true, where: \.isText) {
                session.selectedID = hit.id
                if event.clickCount >= 2 {
                    beginEditingText(hit)
                } else {
                    interaction = .moving(original: hit, start: p, current: hit)
                }
            } else {
                session.selectedID = nil
                beginNewText(at: clampToImage(p))
            }

        case .eraser:
            interaction = .erasing([])
            erase(at: p)

        case .crop:
            if let crop = session.cropRect, crop.contains(p) {
                interaction = .movingCrop(original: crop, start: p)
            } else {
                session.cropRect = nil
                interaction = .cropping(start: clampToImage(p))
            }

        case .pen, .highlighter, .rectangle, .ellipse, .line, .arrow:
            session.selectedID = nil
            let style = session.style(for: session.tool)
            let annotation = Annotation(shape: shape(for: session.tool, from: p, to: p), color: style.color, lineWidth: style.width)
            interaction = .drawing(annotation, start: p)
        }
        refreshLive()
        chromeView.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = viewport.viewToImage(viewPoint)
        mouseLocation = viewPoint

        switch interaction {
        case .none:
            break

        case .drawing(var annotation, let start):
            switch annotation.shape {
            case .pen(var points):
                if shouldAppend(p, to: points) { points.append(p) }
                annotation.shape = .pen(points)
            case .highlighter(var points):
                if event.modifierFlags.contains(.shift) {
                    points = [start, Self.constrainedLineEnd(from: start, to: p)]
                } else if shouldAppend(p, to: points) {
                    points.append(p)
                }
                annotation.shape = .highlighter(points)
            default:
                let end = event.modifierFlags.contains(.shift) ? constrained(from: start, to: p) : p
                annotation.shape = shape(for: session.tool, from: start, to: end)
            }
            interaction = .drawing(annotation, start: start)
            refreshLive()

        case .moving(let original, let start, _):
            let moved = original.translated(by: p.x - start.x, p.y - start.y)
            if !hiddenIDs.contains(original.id) {
                hiddenIDs.insert(original.id)
                annotationsView.needsDisplay = true
            }
            interaction = .moving(original: original, start: start, current: moved)
            refreshLive()
            chromeView.needsDisplay = true

        case .cropping(let start):
            session.cropRect = CropMath.rect(from: start, to: clampToImage(p), within: document.pixelSize)
            chromeView.needsDisplay = true

        case .movingCrop(let original, let start):
            session.cropRect = CropMath.moved(original, by: (p.x - start.x).rounded(), (p.y - start.y).rounded(), within: document.pixelSize)
            chromeView.needsDisplay = true

        case .erasing:
            erase(at: p)
            chromeView.needsDisplay = true

        case .panning(let start, let offset):
            fitsWindow = false
            var next = viewport
            next.offset = CGPoint(x: offset.x + viewPoint.x - start.x, y: offset.y + viewPoint.y - start.y)
            viewport = next.clamped(imageSize: imageSize, viewSize: bounds.size, padding: Self.padding)
            applyViewport()
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .none:
            break

        case .drawing(let annotation, _):
            if isMeaningful(annotation) {
                document.add(annotation, actionName: "Add \(session.tool.title)")
            }

        case .moving(let original, _, let current):
            hiddenIDs.remove(original.id)
            if current != original {
                document.update(current, actionName: "Move")
            }
            annotationsView.needsDisplay = true

        case .cropping:
            if let crop = session.cropRect, crop.width < 2 || crop.height < 2 {
                session.cropRect = nil
            }

        case .movingCrop:
            break

        case .erasing(let ids):
            hiddenIDs.subtract(ids)
            document.removeAnnotations(withIDs: ids)
            annotationsView.needsDisplay = true

        case .panning:
            window?.invalidateCursorRects(for: self)
        }
        interaction = .none
        refreshLive()
        chromeView.needsDisplay = true
    }

    private func shape(for tool: EditorTool, from a: CGPoint, to b: CGPoint) -> Annotation.Shape {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        switch tool {
        case .rectangle: return .rectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .line: return .line(a, b)
        case .highlighter: return .highlighter([a])
        case .arrow: return .arrow(a, b)
        default: return .pen([a])
        }
    }

    /// Shift: squares/circles for boxes, 45° steps for lines and arrows.
    private func constrained(from start: CGPoint, to p: CGPoint) -> CGPoint {
        switch session.tool {
        case .rectangle, .ellipse:
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            return CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
        default:
            return Self.constrainedLineEnd(from: start, to: p)
        }
    }

    private static func constrainedLineEnd(from start: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func shouldAppend(_ p: CGPoint, to points: [CGPoint]) -> Bool {
        guard let last = points.last else { return true }
        return hypot(p.x - last.x, p.y - last.y) >= 0.75 / viewport.zoom
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        let minimum = 3 / viewport.zoom
        switch annotation.shape {
        case .pen(let points), .highlighter(let points): return !points.isEmpty
        case .rectangle(let r), .ellipse(let r): return r.width >= minimum && r.height >= minimum
        case .line(let a, let b), .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) >= minimum
        case .text(let t): return !t.string.isEmpty
        }
    }

    private func erase(at p: CGPoint) {
        guard case .erasing(var ids) = interaction else { return }
        let radius = 8 / viewport.zoom
        let hits = document.annotations.filter { !ids.contains($0.id) && $0.hitTest(p, tolerance: radius) }
        guard !hits.isEmpty else { return }
        for hit in hits { ids.insert(hit.id) }
        hiddenIDs.formUnion(ids)
        interaction = .erasing(ids)
        annotationsView.needsDisplay = true
    }

    /// Invalidates only the area touched by the in-progress annotation.
    private func refreshLive() {
        var rect: CGRect = .null
        switch interaction {
        case .drawing(let annotation, _): rect = viewport.imageToView(annotation.bounds)
        case .moving(_, _, let current): rect = viewport.imageToView(current.bounds)
        default: break
        }
        let padded = rect.isNull ? rect : rect.insetBy(dx: -4, dy: -4)
        let dirty = lastLiveRect.union(padded)
        if !dirty.isNull { liveView.setNeedsDisplay(dirty) }
        lastLiveRect = padded
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 51, 117: // Delete / Forward Delete
            deleteSelection()
            return
        case 36, 76: // Return / Enter
            if session.tool == .crop { applyCrop(); return }
            if let selected = session.selectedAnnotation, selected.isText { beginEditingText(selected); return }
        case 53: // Escape
            cancelOperation(nil)
            return
        case 49: // Space: hold to pan
            if !spaceHeld {
                spaceHeld = true
                window?.invalidateCursorRects(for: self)
            }
            return
        case 123, 124, 125, 126:
            if nudgeSelection(event.keyCode, large: modifiers.contains(.shift)) { return }
        default:
            break
        }
        if modifiers.isEmpty, let character = event.charactersIgnoringModifiers?.first, let tool = EditorTool.tool(forKey: character) {
            session.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            window?.invalidateCursorRects(for: self)
        } else {
            super.keyUp(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if case .none = interaction {} else {
            interaction = .none
            hiddenIDs.removeAll()
            annotationsView.needsDisplay = true
            refreshLive()
            return
        }
        if session.cropRect != nil {
            session.cropRect = nil
            chromeView.needsDisplay = true
        } else if session.selectedID != nil {
            session.selectedID = nil
        } else {
            session.controller?.cancel()
        }
    }

    private func nudgeSelection(_ keyCode: UInt16, large: Bool) -> Bool {
        guard let selected = session.selectedAnnotation else { return false }
        let step: CGFloat = large ? 10 : 1
        let (dx, dy): (CGFloat, CGFloat) = switch keyCode {
        case 123: (-step, 0)
        case 124: (step, 0)
        case 125: (0, step)
        default: (0, -step)
        }
        document.update(selected.translated(by: dx, dy), actionName: "Move", coalescingKey: "nudge-\(selected.id)")
        return true
    }

    func deleteSelection() {
        guard let id = session.selectedID else { return }
        document.removeAnnotations(withIDs: [id], actionName: "Delete")
        session.selectedID = nil
    }

    func applyCrop() {
        guard let crop = session.cropRect else { return }
        if document.crop(to: crop) {
            session.cropRect = nil
            session.tool = session.lastDrawingTool
        }
    }

    func cancelCrop() {
        session.cropRect = nil
        chromeView.needsDisplay = true
    }

    // MARK: - Commands

    private var fieldEditor: NSTextView? {
        guard editingText != nil else { return nil }
        return window?.firstResponder as? NSTextView
    }

    @objc func snapUndo(_ sender: Any?) {
        if let fieldEditor {
            fieldEditor.undoManager?.undo()
            return
        }
        resetTransientState()
        document.undo()
    }

    @objc func snapRedo(_ sender: Any?) {
        if let fieldEditor {
            fieldEditor.undoManager?.redo()
            return
        }
        resetTransientState()
        document.redo()
    }

    @objc func copy(_ sender: Any?) {
        session.controller?.copyToClipboard()
    }

    @objc func copyAndClose(_ sender: Any?) {
        session.controller?.copyAndClose()
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(snapUndo(_:)):
            if let fieldEditor { return fieldEditor.undoManager?.canUndo ?? false }
            menuItem.title = document.undoActionName.map { "Undo \($0)" } ?? "Undo"
            return document.canUndo
        case #selector(snapRedo(_:)):
            if let fieldEditor { return fieldEditor.undoManager?.canRedo ?? false }
            menuItem.title = document.redoActionName.map { "Redo \($0)" } ?? "Redo"
            return document.canRedo
        case #selector(delete(_:)):
            return session.selectedID != nil
        default:
            return true
        }
    }

    private func resetTransientState() {
        commitTextEditing()
        interaction = .none
        hiddenIDs.removeAll()
        refreshLive()
    }

    // MARK: - Text editing

    private func beginNewText(at origin: CGPoint) {
        startTextField(string: "", origin: origin, fontSize: session.fontSize, color: session.color, existingID: nil)
    }

    private func beginEditingText(_ annotation: Annotation) {
        guard let text = annotation.textContent else { return }
        session.tool = .text
        session.selectedID = annotation.id
        hiddenIDs.insert(annotation.id)
        annotationsView.needsDisplay = true
        startTextField(string: text.string, origin: text.origin, fontSize: text.fontSize, color: annotation.color, existingID: annotation.id)
    }

    private func startTextField(string: String, origin: CGPoint, fontSize: CGFloat, color: RGBAColor, existingID: UUID?) {
        let field = NSTextField(string: string)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.textColor = NSColor(cgColor: color.cgColor)
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 3
        field.setAccessibilityLabel("Annotation text")
        editingText = EditingText(field: field, origin: origin, fontSize: fontSize, color: color, existingID: existingID)
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
        session.isEditingText = true
    }

    private func layoutTextField() {
        guard let editing = editingText else { return }
        let size = TextLayout.size(of: editing.field.stringValue, fontSize: editing.fontSize)
        let origin = viewport.imageToView(editing.origin)
        editing.field.font = TextLayout.font(size: editing.fontSize * viewport.zoom)
        // NSTextField insets its text by ~2pt; shift so the committed text lands where it was typed.
        editing.field.frame = CGRect(
            x: origin.x - 2,
            y: origin.y - 1,
            width: max(size.width * viewport.zoom + 10, 48),
            height: size.height * viewport.zoom + 2
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        layoutTextField()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelTextEditing()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitTextEditing()
            return true
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            layoutTextField()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }

    /// Turns the text being typed into an annotation (or removes an existing one that was emptied).
    func commitTextEditing() {
        guard let editing = finishTextField() else { return }
        let string = editing.field.stringValue
        let isBlank = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let content = TextContent(string: string, origin: editing.origin, fontSize: editing.fontSize)
        if let id = editing.existingID, var annotation = document.annotation(withID: id) {
            if isBlank {
                document.removeAnnotations(withIDs: [id], actionName: "Delete Text")
            } else {
                annotation.shape = .text(content)
                annotation.color = editing.color
                document.update(annotation, actionName: "Edit Text")
            }
        } else if !isBlank {
            let annotation = Annotation(shape: .text(content), color: editing.color, lineWidth: 0)
            document.add(annotation, actionName: "Add Text")
            session.selectedID = annotation.id
        }
        annotationsView.needsDisplay = true
    }

    func cancelTextEditing() {
        guard finishTextField() != nil else { return }
        annotationsView.needsDisplay = true
    }

    private func finishTextField() -> EditingText? {
        guard let editing = editingText else { return nil }
        editingText = nil
        editing.field.delegate = nil
        editing.field.removeFromSuperview()
        if let id = editing.existingID { hiddenIDs.remove(id) }
        session.isEditingText = false
        window?.makeFirstResponder(self)
        return editing
    }

    // MARK: - Drawing

    private func inImageSpace(_ context: CGContext, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: viewport.offset.x, y: viewport.offset.y)
        context.scaleBy(x: viewport.zoom, y: viewport.zoom)
        context.clip(to: CGRect(origin: .zero, size: imageSize))
        body()
        context.restoreGState()
    }

    private func drawAnnotations(in context: CGContext) {
        inImageSpace(context) {
            for annotation in document.annotations where !hiddenIDs.contains(annotation.id) {
                AnnotationDrawer.draw(annotation, in: context)
            }
        }
    }

    private func drawLive(in context: CGContext) {
        let annotation: Annotation?
        switch interaction {
        case .drawing(let a, _): annotation = a
        case .moving(_, _, let current): annotation = current
        default: annotation = nil
        }
        guard let annotation else { return }
        inImageSpace(context) { AnnotationDrawer.draw(annotation, in: context) }
    }

    private func drawChrome(in context: CGContext) {
        let imageRect = viewport.imageToView(CGRect(origin: .zero, size: imageSize))

        if session.tool == .crop {
            drawCropChrome(imageRect: imageRect, in: context)
        }

        var selected = session.selectedAnnotation
        if case .moving(_, _, let current) = interaction { selected = current }
        if let selected, editingText == nil {
            let rect = viewport.imageToView(selected.bounds).insetBy(dx: -4, dy: -4)
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(rect)
            context.restoreGState()
        }

        if session.tool == .eraser, let mouse = mouseLocation {
            let r: CGFloat = 8
            context.saveGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: CGRect(x: mouse.x - r, y: mouse.y - r, width: r * 2, height: r * 2))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x: mouse.x - r, y: mouse.y - r, width: r * 2, height: r * 2))
            context.restoreGState()
        }
    }

    private func drawCropChrome(imageRect: CGRect, in context: CGContext) {
        guard let crop = session.cropRect else {
            drawBadge("Drag to choose the area to keep", centeredAt: CGPoint(x: imageRect.midX, y: imageRect.minY + 28))
            return
        }
        let rect = viewport.imageToView(crop)
        context.saveGState()
        context.addRect(imageRect)
        context.addRect(rect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect)
        let corner = min(16, rect.width / 3, rect.height / 3)
        context.setLineWidth(4)
        for (p, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            context.move(to: CGPoint(x: p.x + corner * dx, y: p.y))
            context.addLine(to: p)
            context.addLine(to: CGPoint(x: p.x, y: p.y + corner * dy))
        }
        context.strokePath()
        context.restoreGState()

        let label = "\(Int(crop.width)) × \(Int(crop.height))"
        let labelY = rect.minY - 18 > imageRect.minY ? rect.minY - 16 : rect.maxY + 16
        drawBadge(label, centeredAt: CGPoint(x: rect.midX, y: labelY))
    }

    private func drawBadge(_ text: String, centeredAt center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: center.x - size.width / 2 - 7, y: center.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }
}

/// Shows the screenshot as layer contents so zooming and scrolling are handled by the GPU.
final class ImageLayerView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    func updateFilters(devicePixelsPerImagePixel: CGFloat) {
        // Show crisp pixels when zoomed in past 2×, smooth filtering otherwise.
        layer?.magnificationFilter = devicePixelsPerImagePixel >= 2 ? .nearest : .linear
        layer?.minificationFilter = .trilinear
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A transparent overlay drawn by a closure; it never intercepts the mouse.
final class DrawingView: NSView {
    var drawHandler: ((CGContext) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clip(to: dirtyRect)
        drawHandler?(context)
    }
}
