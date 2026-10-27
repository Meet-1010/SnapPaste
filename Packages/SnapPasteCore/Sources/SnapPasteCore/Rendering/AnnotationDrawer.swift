import CoreGraphics
import CoreText

/// Draws annotations into a context whose user space is image pixels with a top-left origin (y down).
///
/// The editor canvas and the final export both use this, so what you see is what gets copied.
public enum AnnotationDrawer {
    public static func draw(_ annotations: [Annotation], in context: CGContext) {
        for annotation in annotations {
            draw(annotation, in: context)
        }
    }

    public static func draw(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let color = annotation.color.cgColor
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case .pen(let points), .highlighter(let points):
            guard let first = points.first else { return }
            if points.count == 1 {
                let r = annotation.lineWidth / 2
                context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
            } else {
                context.addPath(smoothPath(through: points))
                context.strokePath()
            }
        case .rectangle(let rect):
            context.setLineJoin(.miter)
            context.stroke(rect.standardized)
        case .ellipse(let rect):
            context.strokeEllipse(in: rect.standardized)
        case .line(let a, let b):
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
        case .arrow(let a, let b):
            guard let g = ArrowGeometry.geometry(from: a, to: b, lineWidth: annotation.lineWidth) else { return }
            context.move(to: a)
            context.addLine(to: g.shaftEnd)
            context.strokePath()
            context.setLineWidth(max(1, annotation.lineWidth * 0.25))
            context.move(to: g.tip)
            context.addLine(to: g.left)
            context.addLine(to: g.right)
            context.closePath()
            context.drawPath(using: .fillStroke)
        case .text(let text):
            drawText(text, color: color, in: context)
        }
    }

    /// A smooth curve through the sampled pointer positions (quadratic segments between midpoints).
    public static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let control = points[i]
            let next = points[i + 1]
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func drawText(_ text: TextContent, color: CGColor, in context: CGContext) {
        let attributed = TextLayout.attributedString(text.string, fontSize: text.fontSize, color: color)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = TextLayout.size(of: text.string, fontSize: text.fontSize)
        context.saveGState()
        // CoreText draws in a y-up space, so flip locally around the text box.
        context.translateBy(x: text.origin.x, y: text.origin.y + size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
