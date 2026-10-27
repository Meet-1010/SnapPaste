#if DEBUG
import AppKit
import SnapPasteCore

extension AppController {
    /// Debug builds only: opens the editor on a generated image so the editor can be exercised
    /// without Screen Recording permission.
    func openSampleCaptureForTesting() {
        let size = PixelSize(width: 1600, height: 1000)
        guard let context = ImageRenderer.makeContext(size: size) else { return }
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(size.bounds)
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 90))
        let sample = [
            Annotation(shape: .text(TextContent(string: "SnapPaste sample capture", origin: CGPoint(x: 60, y: 160), fontSize: 64)), color: .black, lineWidth: 0),
            Annotation(shape: .text(TextContent(string: "The quick brown fox jumps over the lazy dog.", origin: CGPoint(x: 60, y: 300), fontSize: 44)), color: .black, lineWidth: 0),
            Annotation(shape: .text(TextContent(string: "Error 404: page not found", origin: CGPoint(x: 60, y: 420), fontSize: 44)), color: .red, lineWidth: 0),
        ]
        AnnotationDrawer.draw(sample, in: context)
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.92, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 60, y: 560, width: 700, height: 360))
        context.fill(CGRect(x: 840, y: 560, width: 700, height: 360))
        guard let image = context.makeImage() else { return }
        let document = captureStore.replace(with: image)
        openEditorForTesting(document)
    }
}
#endif
