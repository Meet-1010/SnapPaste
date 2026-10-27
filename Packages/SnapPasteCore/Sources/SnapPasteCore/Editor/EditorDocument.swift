import CoreGraphics
import Foundation
import Observation

/// The image being edited plus its annotations.
public struct EditorState: Equatable {
    public var image: CGImage
    public var annotations: [Annotation]

    public init(image: CGImage, annotations: [Annotation] = []) {
        self.image = image
        self.annotations = annotations
    }

    public var pixelSize: PixelSize { PixelSize(image) }

    public static func == (lhs: EditorState, rhs: EditorState) -> Bool {
        lhs.image === rhs.image && lhs.annotations == rhs.annotations
    }
}

/// An in-memory editing session for one capture. Nothing here is ever written to disk.
@MainActor
@Observable
public final class EditorDocument {
    public private(set) var state: EditorState
    /// The capture as it arrived, kept for Reset.
    public let original: EditorState
    private var history: EditHistory<EditorState>

    /// Called after every change, including undo and redo.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(image: CGImage, historyLimit: Int = 100) {
        let initial = EditorState(image: image)
        state = initial
        original = initial
        history = EditHistory(limit: historyLimit)
    }

    public var image: CGImage { state.image }
    public var annotations: [Annotation] { state.annotations }
    public var pixelSize: PixelSize { state.pixelSize }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var undoActionName: String? { history.undoActionName }
    public var redoActionName: String? { history.redoActionName }
    public var hasEdits: Bool { state != original }

    public func annotation(withID id: UUID) -> Annotation? {
        state.annotations.first { $0.id == id }
    }

    /// Applies a change as one undoable step. Returns false (and records nothing) if nothing changed.
    @discardableResult
    public func perform(_ actionName: String, coalescingKey: String? = nil, _ change: (inout EditorState) -> Void) -> Bool {
        var next = state
        change(&next)
        guard next != state else { return false }
        history.record(previous: state, actionName: actionName, coalescingKey: coalescingKey)
        state = next
        onChange?()
        return true
    }

    public func breakCoalescing() {
        history.breakCoalescing()
    }

    public func undo() {
        guard let previous = history.undo(current: state) else { return }
        state = previous
        onChange?()
    }

    public func redo() {
        guard let next = history.redo(current: state) else { return }
        state = next
        onChange?()
    }

    // MARK: Annotation edits

    public func add(_ annotation: Annotation, actionName: String = "Add Annotation") {
        perform(actionName) { $0.annotations.append(annotation) }
    }

    @discardableResult
    public func removeAnnotations(withIDs ids: Set<UUID>, actionName: String = "Erase") -> Bool {
        guard !ids.isEmpty else { return false }
        return perform(actionName) { $0.annotations.removeAll { ids.contains($0.id) } }
    }

    @discardableResult
    public func update(_ annotation: Annotation, actionName: String, coalescingKey: String? = nil) -> Bool {
        perform(actionName, coalescingKey: coalescingKey) { state in
            guard let index = state.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            state.annotations[index] = annotation
        }
    }

    // MARK: Image edits

    /// Crops to `rect` (current image pixels). Annotations move with the content; ones that end up
    /// completely outside the new bounds are dropped (undo brings them back).
    @discardableResult
    public func crop(to rect: CGRect) -> Bool {
        let size = state.pixelSize
        guard CropMath.changesImage(rect, within: size) else { return false }
        let r = CropMath.snapped(rect, within: size)
        guard let cropped = ImageRenderer.crop(state.image, to: r) else { return false }
        return perform("Crop") { state in
            state.image = cropped
            let bounds = PixelSize(cropped).bounds
            state.annotations = state.annotations
                .map { $0.translated(by: -r.minX, -r.minY) }
                .filter { $0.bounds.intersects(bounds) }
        }
    }

    /// Resizes the image to `size` and scales annotations with it.
    public func resize(to size: PixelSize) throws {
        if let issue = ResizeMath.validate(size) { throw issue }
        let current = state.pixelSize
        guard size != current else { return }
        guard let resized = ImageRenderer.resize(state.image, to: size) else { throw ResizeMath.Issue.exceedsMaxPixelCount }
        let sx = CGFloat(size.width) / CGFloat(current.width)
        let sy = CGFloat(size.height) / CGFloat(current.height)
        perform("Resize") { state in
            state.image = resized
            state.annotations = state.annotations.map { $0.scaled(sx: sx, sy: sy) }
        }
    }

    /// Returns to the original capture as a single undoable step.
    public func resetToOriginal() {
        perform("Reset") { $0 = self.original }
    }

    /// The final image with annotations flattened in.
    public func renderedImage() -> CGImage? {
        ImageRenderer.render(state.image, annotations: state.annotations)
    }
}
