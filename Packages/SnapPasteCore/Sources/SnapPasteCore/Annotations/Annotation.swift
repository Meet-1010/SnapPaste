import CoreGraphics
import Foundation

public struct TextContent: Equatable, Sendable {
    public var string: String
    /// Top-left corner of the text box in image pixels.
    public var origin: CGPoint
    /// Font size in image pixels.
    public var fontSize: CGFloat

    public init(string: String, origin: CGPoint, fontSize: CGFloat) {
        self.string = string
        self.origin = origin
        self.fontSize = fontSize
    }
}

/// A vector annotation drawn on top of the captured image.
///
/// Annotations stay separate objects (in image pixel coordinates, top-left origin) until the final
/// image is rendered, so they can be selected, moved, erased and undone without touching the capture.
public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case rectangle(CGRect)
        case ellipse(CGRect)
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case text(TextContent)
    }

    public let id: UUID
    public var shape: Shape
    /// Highlighter opacity is stored in the color's alpha.
    public var color: RGBAColor
    /// Stroke width in image pixels (unused for text).
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), shape: Shape, color: RGBAColor, lineWidth: CGFloat) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }

    public var isText: Bool {
        if case .text = shape { return true }
        return false
    }

    public var textContent: TextContent? {
        if case .text(let content) = shape { return content }
        return nil
    }
}

// MARK: - Geometry

extension Annotation {
    /// Bounding box in image pixels, including stroke width and arrow heads.
    public var bounds: CGRect {
        let pad = lineWidth / 2 + 1
        switch shape {
        case .pen(let points), .highlighter(let points):
            return Self.boundingRect(of: points).insetBy(dx: -pad, dy: -pad)
        case .rectangle(let rect), .ellipse(let rect):
            return rect.standardized.insetBy(dx: -pad, dy: -pad)
        case .line(let a, let b):
            return Self.boundingRect(of: [a, b]).insetBy(dx: -pad, dy: -pad)
        case .arrow(let a, let b):
            let head = ArrowGeometry.headLength(for: lineWidth)
            return Self.boundingRect(of: [a, b]).insetBy(dx: -(pad + head), dy: -(pad + head))
        case .text(let text):
            return CGRect(origin: text.origin, size: TextLayout.size(of: text.string, fontSize: text.fontSize))
        }
    }

    public func translated(by dx: CGFloat, _ dy: CGFloat) -> Annotation {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        var copy = self
        switch shape {
        case .pen(let points): copy.shape = .pen(points.map(t))
        case .highlighter(let points): copy.shape = .highlighter(points.map(t))
        case .rectangle(let rect): copy.shape = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case .ellipse(let rect): copy.shape = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        case .line(let a, let b): copy.shape = .line(t(a), t(b))
        case .arrow(let a, let b): copy.shape = .arrow(t(a), t(b))
        case .text(var text):
            text.origin = t(text.origin)
            copy.shape = .text(text)
        }
        return copy
    }

    /// Scales all coordinates about the image origin, e.g. after the image is resized.
    public func scaled(sx: CGFloat, sy: CGFloat) -> Annotation {
        func s(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        func s(_ r: CGRect) -> CGRect { CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy) }
        let average = (sx + sy) / 2
        var copy = self
        copy.lineWidth = max(0.5, lineWidth * average)
        switch shape {
        case .pen(let points): copy.shape = .pen(points.map(s))
        case .highlighter(let points): copy.shape = .highlighter(points.map(s))
        case .rectangle(let rect): copy.shape = .rectangle(s(rect))
        case .ellipse(let rect): copy.shape = .ellipse(s(rect))
        case .line(let a, let b): copy.shape = .line(s(a), s(b))
        case .arrow(let a, let b): copy.shape = .arrow(s(a), s(b))
        case .text(var text):
            text.origin = s(text.origin)
            text.fontSize = max(1, text.fontSize * average)
            copy.shape = .text(text)
        }
        return copy
    }

    /// Whether `point` (image pixels) touches the annotation.
    /// Closed shapes count their interior only when `includeInterior` is true; text always does.
    public func hitTest(_ point: CGPoint, tolerance: CGFloat, includeInterior: Bool = false) -> Bool {
        let reach = lineWidth / 2 + tolerance
        switch shape {
        case .pen(let points), .highlighter(let points):
            guard let first = points.first else { return false }
            if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= reach }
            for i in 1..<points.count where Self.distance(from: point, toSegment: points[i - 1], points[i]) <= reach {
                return true
            }
            return false
        case .rectangle(let rect):
            let r = rect.standardized
            if includeInterior && r.contains(point) { return true }
            return Self.distance(from: point, toRectBorder: r) <= reach
        case .ellipse(let rect):
            let r = rect.standardized
            let a = r.width / 2, b = r.height / 2
            guard a > 0, b > 0 else { return Self.distance(from: point, toRectBorder: r) <= reach }
            let nx = (point.x - r.midX) / a, ny = (point.y - r.midY) / b
            let v = (nx * nx + ny * ny).squareRoot()
            if includeInterior && v <= 1 { return true }
            return abs(v - 1) * min(a, b) <= reach
        case .line(let a, let b):
            return Self.distance(from: point, toSegment: a, b) <= reach
        case .arrow(let a, let b):
            if Self.distance(from: point, toSegment: a, b) <= reach { return true }
            return hypot(point.x - b.x, point.y - b.y) <= ArrowGeometry.headLength(for: lineWidth) * 0.6 + tolerance
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(from p: CGPoint, toRectBorder r: CGRect) -> CGFloat {
        if r.contains(p) {
            return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

/// Arrow head geometry shared by drawing and hit testing.
public enum ArrowGeometry {
    public static func headLength(for lineWidth: CGFloat) -> CGFloat {
        max(12, lineWidth * 4)
    }

    /// Returns where the shaft should end and the three head vertices, or nil for a degenerate arrow.
    public static func geometry(from start: CGPoint, to tip: CGPoint, lineWidth: CGFloat)
        -> (shaftEnd: CGPoint, tip: CGPoint, left: CGPoint, right: CGPoint)?
    {
        let dx = tip.x - start.x, dy = tip.y - start.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return nil }
        let ux = dx / length, uy = dy / length
        let headLength = min(headLength(for: lineWidth), length)
        let halfWidth = headLength * 0.45
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        let left = CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth)
        let right = CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        // End the shaft inside the head so its round cap never pokes past the tip.
        let shaftEnd = CGPoint(x: tip.x - ux * headLength * 0.5, y: tip.y - uy * headLength * 0.5)
        return (shaftEnd, tip, left, right)
    }
}
