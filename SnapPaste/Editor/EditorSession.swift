import AppKit
import SnapPasteCore

/// UI state for one editor window: current tool, styles, selection and crop rectangle.
/// The document itself (image + annotations + history) lives in `EditorDocument`.
@Observable
final class EditorSession {
    let document: EditorDocument

    var tool: EditorTool = .arrow {
        didSet {
            guard oldValue != tool else { return }
            if oldValue.drawsAnnotations { lastDrawingTool = oldValue }
            canvas?.toolDidChange(from: oldValue)
        }
    }
    @ObservationIgnored private(set) var lastDrawingTool: EditorTool = .arrow

    var color: RGBAColor
    var lineWidth: Double
    var highlighterColor: RGBAColor = .yellow
    var highlighterWidth: Double = 28
    var highlighterOpacity: Double
    var fontSize: Double

    var selectedID: UUID? {
        didSet { if oldValue != selectedID { canvas?.selectionDidChange() } }
    }
    var cropRect: CGRect?
    var zoomPercent = 100
    var isEditingText = false

    @ObservationIgnored weak var canvas: EditorCanvasView?
    @ObservationIgnored weak var controller: EditorWindowController?

    init(document: EditorDocument, settings: SettingsStore) {
        self.document = document
        color = settings.annotationColor
        lineWidth = settings.lineWidth
        highlighterOpacity = settings.highlighterOpacity
        fontSize = settings.textSize
        highlighterWidth = max(12, settings.lineWidth * 4)
    }

    var selectedAnnotation: Annotation? {
        selectedID.flatMap { document.annotation(withID: $0) }
    }

    /// Style controls act on the selection if there is one, otherwise on the next annotation drawn.
    var editsHighlighter: Bool {
        if let selected = selectedAnnotation {
            if case .highlighter = selected.shape { return true }
            return false
        }
        return tool == .highlighter
    }

    var editsText: Bool {
        if let selected = selectedAnnotation { return selected.isText }
        return tool == .text || isEditingText
    }

    var activeColor: RGBAColor { editsHighlighter ? highlighterColor : color }
    var activeWidth: Double { editsHighlighter ? highlighterWidth : lineWidth }

    func style(for tool: EditorTool) -> (color: RGBAColor, width: CGFloat) {
        tool == .highlighter
            ? (highlighterColor.withAlpha(highlighterOpacity), highlighterWidth)
            : (color, lineWidth)
    }

    func setColor(_ newColor: RGBAColor) {
        if editsHighlighter { highlighterColor = newColor } else { color = newColor }
        if var selected = selectedAnnotation {
            let alpha: Double
            if case .highlighter = selected.shape { alpha = highlighterOpacity } else { alpha = 1 }
            selected.color = newColor.withAlpha(alpha)
            document.update(selected, actionName: "Change Color")
        }
        canvas?.styleDidChange()
    }

    func setWidth(_ width: Double) {
        if editsHighlighter { highlighterWidth = width } else { lineWidth = width }
        if var selected = selectedAnnotation, !selected.isText {
            selected.lineWidth = width
            document.update(selected, actionName: "Change Thickness", coalescingKey: "width-\(selected.id)")
        }
    }

    func setOpacity(_ opacity: Double) {
        highlighterOpacity = opacity
        if var selected = selectedAnnotation, case .highlighter = selected.shape {
            selected.color = selected.color.withAlpha(opacity)
            document.update(selected, actionName: "Change Opacity", coalescingKey: "opacity-\(selected.id)")
        }
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        if var selected = selectedAnnotation, var text = selected.textContent {
            text.fontSize = size
            selected.shape = .text(text)
            document.update(selected, actionName: "Change Text Size", coalescingKey: "font-\(selected.id)")
        }
        canvas?.styleDidChange()
    }

    /// Ends a slider drag so the next change is a separate undo step.
    func finishStyleChange() {
        document.breakCoalescing()
    }

    /// Mirrors a selected annotation's style in the controls.
    func adoptStyle(of annotation: Annotation) {
        switch annotation.shape {
        case .highlighter:
            highlighterColor = annotation.color.withAlpha(1)
            highlighterWidth = annotation.lineWidth
            highlighterOpacity = annotation.color.alpha
        case .text(let text):
            color = annotation.color
            fontSize = text.fontSize
        default:
            color = annotation.color
            lineWidth = annotation.lineWidth
        }
    }
}
