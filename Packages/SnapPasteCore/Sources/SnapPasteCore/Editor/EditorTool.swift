public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case select, crop, pen, highlighter, rectangle, ellipse, line, arrow, text, eraser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .eraser: "Eraser"
        }
    }

    public var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }

    /// Single-key shortcut inside the editor.
    public var key: Character {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .pen: "p"
        case .highlighter: "h"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .eraser: "e"
        }
    }

    public static func tool(forKey key: Character) -> EditorTool? {
        allCases.first { $0.key == Character(key.lowercased()) }
    }

    public var drawsAnnotations: Bool {
        switch self {
        case .pen, .highlighter, .rectangle, .ellipse, .line, .arrow, .text: true
        case .select, .crop, .eraser: false
        }
    }

    public var usesStroke: Bool {
        switch self {
        case .pen, .highlighter, .rectangle, .ellipse, .line, .arrow: true
        default: false
        }
    }
}
