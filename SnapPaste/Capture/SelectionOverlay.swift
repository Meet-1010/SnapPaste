import AppKit
import SnapPasteCore

/// Full-screen, borderless panel used for picking what to capture. It is non-activating, so the
/// app the user is working in stays frontmost (its windows keep their active appearance).
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Presents one overlay per display and reports what the user picked.
final class SelectionOverlayController {
    enum Mode {
        case region
        case window([WindowCandidate])
        case display
    }

    enum Result {
        /// `rect` is in display-local points with a top-left origin.
        case region(rect: CGRect, displayID: CGDirectDisplayID)
        case window(WindowCandidate)
        case display(CGDirectDisplayID)
        case cancelled
    }

    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Result, Never>?
    private var screenObserver: NSObjectProtocol?

    func run(_ mode: Mode) async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(mode)
        }
    }

    private func present(_ mode: Mode) {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let panel = OverlayPanel(screen: screen)
            let finish: (Result) -> Void = { [weak self] result in self?.finish(result) }
            let view: NSView
            switch mode {
            case .region:
                view = RegionSelectionView(screen: screen, displayID: displayID, finish: finish)
            case .window(let candidates):
                view = WindowPickerView(screen: screen, candidates: candidates, finish: finish)
            case .display:
                view = DisplayPickerView(screen: screen, displayID: displayID, finish: finish)
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            if NSMouseInRect(mouse, screen.frame, false) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
        }
        if panels.isEmpty {
            finish(.cancelled)
            return
        }
        if !panels.contains(where: \.isKeyWindow), let first = panels.first {
            first.makeKey()
            first.makeFirstResponder(first.contentView)
        }
        NSCursor.crosshair.set()
        // Display configuration changes invalidate the overlay geometry, so cancel cleanly.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        continuation.resume(returning: result)
    }
}

// MARK: - Shared overlay view behavior

class OverlayView: NSView {
    let screen: NSScreen
    let finish: (SelectionOverlayController.Result) -> Void

    init(screen: NSScreen, finish: @escaping (SelectionOverlayController.Result) -> Void) {
        self.screen = screen
        self.finish = finish
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        let options: NSTrackingArea.Options = [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(.cancelled) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { finish(.cancelled) }
    override func rightMouseDown(with event: NSEvent) { finish(.cancelled) }

    /// Converts a Cocoa global point to this view's flipped, screen-local coordinates.
    func localPoint(fromGlobal point: NSPoint) -> NSPoint {
        NSPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
    }

    func drawLabel(_ text: String, near anchor: CGPoint, avoiding rect: CGRect? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var box = CGRect(x: anchor.x, y: anchor.y, width: size.width + 12, height: size.height + 6)
        box.origin.x = min(max(4, box.origin.x), bounds.width - box.width - 4)
        box.origin.y = min(max(4, box.origin.y), bounds.height - box.height - 4)
        if let rect, rect.intersects(box) {
            box.origin.y = max(4, rect.minY - box.height - 6)
        }
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }
}

// MARK: - Region selection

final class RegionSelectionView: OverlayView {
    private let displayID: CGDirectDisplayID
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var mouse: CGPoint?

    init(screen: NSScreen, displayID: CGDirectDisplayID, finish: @escaping (SelectionOverlayController.Result) -> Void) {
        self.displayID = displayID
        super.init(screen: screen, finish: finish)
        setAccessibilityLabel("Drag to select a region to capture. Press Escape to cancel.")
    }

    private var selection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = clamped(convert(event.locationInWindow, from: nil))
        dragStart = p
        dragCurrent = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var p = clamped(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift), let start = dragStart {
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            p = clamped(CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side)))
        }
        dragCurrent = p
        mouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selection else { return }
        // A click or tiny drag is treated as a miss; the overlay stays up so the user can try again.
        if rect.width < 3 || rect.height < 3 {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
            return
        }
        finish(.region(rect: rect, displayID: displayID))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / Enter with no selection captures this whole display.
            if selection == nil { finish(.region(rect: bounds, displayID: displayID)) }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.28)
        guard let rect = selection, rect.width > 0, rect.height > 0 else {
            dim.setFill()
            bounds.fill()
            if let mouse {
                drawCrosshairGuides(at: mouse)
                drawLabel("Drag to capture · ↩ full screen · esc cancel", near: CGPoint(x: mouse.x + 16, y: mouse.y + 18))
            }
            return
        }
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: rect).reversed)
        dim.setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let pixels = ScreenGeometry.pixelSize(of: rect, scale: screen.backingScaleFactor)
        drawLabel("\(pixels.width) × \(pixels.height)", near: CGPoint(x: rect.maxX - 70, y: rect.maxY + 8), avoiding: rect)
    }

    private func drawCrosshairGuides(at p: CGPoint) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: p.y))
        path.line(to: CGPoint(x: bounds.width, y: p.y))
        path.move(to: CGPoint(x: p.x, y: 0))
        path.line(to: CGPoint(x: p.x, y: bounds.height))
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
    }
}

// MARK: - Window picking

final class WindowPickerView: OverlayView {
    private let candidates: [WindowCandidate]
    private var hovered: WindowCandidate?

    init(screen: NSScreen, candidates: [WindowCandidate], finish: @escaping (SelectionOverlayController.Result) -> Void) {
        self.candidates = candidates
        super.init(screen: screen, finish: finish)
        hovered = candidate(at: NSEvent.mouseLocation)
        setAccessibilityLabel("Click a window to capture it. Press Escape to cancel.")
    }

    private func candidate(at globalPoint: NSPoint) -> WindowCandidate? {
        guard NSMouseInRect(globalPoint, screen.frame, false) else { return nil }
        return candidates.first { NSMouseInRect(globalPoint, $0.frame, false) }
    }

    private func updateHover(_ event: NSEvent) {
        let global = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let next = candidate(at: global)
        if next != hovered {
            hovered = next
            needsDisplay = true
        }
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseDragged(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        updateHover(event)
        if let hovered { finish(.window(hovered)) }
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), let hovered {
            finish(.window(hovered))
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        guard let hovered else {
            if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) {
                drawLabel(candidates.isEmpty ? "No capturable windows · esc cancel" : "Click a window to capture · esc cancel",
                          near: CGPoint(x: bounds.midX - 120, y: 40))
            }
            return
        }
        let rect = ScreenGeometry.localTopLeftRect(hovered.frame, screenFrame: screen.frame)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        rect.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        border.lineWidth = 2
        border.stroke()
        let pixels = ScreenGeometry.pixelSize(of: hovered.frame, scale: screen.backingScaleFactor)
        drawLabel("\(hovered.label)  \(pixels.width) × \(pixels.height)",
                  near: CGPoint(x: rect.minX + 8, y: max(rect.minY + 8, 8)))
    }
}

// MARK: - Display picking

final class DisplayPickerView: OverlayView {
    private let displayID: CGDirectDisplayID
    private var isHovered: Bool

    init(screen: NSScreen, displayID: CGDirectDisplayID, finish: @escaping (SelectionOverlayController.Result) -> Void) {
        self.displayID = displayID
        isHovered = NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        super.init(screen: screen, finish: finish)
        setAccessibilityLabel("Click to capture this display. Press Escape to cancel.")
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { finish(.display(displayID)) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { finish(.display(displayID)) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else {
            NSColor.black.withAlphaComponent(0.3).setFill()
            bounds.fill()
            return
        }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 4
        border.stroke()
        let pixels = ScreenGeometry.pixelSize(of: screen.frame, scale: screen.backingScaleFactor)
        drawLabel("Click to capture \(screen.localizedName)  \(pixels.width) × \(pixels.height) · esc cancel",
                  near: CGPoint(x: bounds.midX - 160, y: bounds.midY))
    }
}
