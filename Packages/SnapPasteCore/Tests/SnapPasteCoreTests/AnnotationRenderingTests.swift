import CoreGraphics
import XCTest
@testable import SnapPasteCore

final class AnnotationTests: XCTestCase {
    func testPenHitTestingFollowsStroke() {
        let a = Annotation(shape: .pen([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]), color: .red, lineWidth: 4)
        XCTAssertTrue(a.hitTest(CGPoint(x: 50, y: 3), tolerance: 2))
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 10), tolerance: 2))
        XCTAssertFalse(a.hitTest(CGPoint(x: 120, y: 0), tolerance: 2))
    }

    func testRectangleBorderVersusInterior() {
        let a = Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 100)), color: .red, lineWidth: 4)
        XCTAssertTrue(a.hitTest(CGPoint(x: 11, y: 50), tolerance: 1))
        XCTAssertFalse(a.hitTest(CGPoint(x: 60, y: 60), tolerance: 1))
        XCTAssertTrue(a.hitTest(CGPoint(x: 60, y: 60), tolerance: 1, includeInterior: true))
    }

    func testEllipseHitTesting() {
        let a = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 200, height: 100)), color: .red, lineWidth: 4)
        XCTAssertTrue(a.hitTest(CGPoint(x: 100, y: 1), tolerance: 2))
        XCTAssertFalse(a.hitTest(CGPoint(x: 100, y: 50), tolerance: 2))
        XCTAssertTrue(a.hitTest(CGPoint(x: 100, y: 50), tolerance: 2, includeInterior: true))
        XCTAssertFalse(a.hitTest(CGPoint(x: 5, y: 5), tolerance: 2, includeInterior: true))
    }

    func testTextHitTestingUsesLaidOutBounds() {
        let a = Annotation(shape: .text(TextContent(string: "Hello", origin: CGPoint(x: 100, y: 100), fontSize: 40)), color: .red, lineWidth: 0)
        XCTAssertGreaterThan(a.bounds.width, 60)
        XCTAssertGreaterThan(a.bounds.height, 40)
        XCTAssertTrue(a.hitTest(CGPoint(x: 120, y: 120), tolerance: 0))
        XCTAssertFalse(a.hitTest(CGPoint(x: 90, y: 90), tolerance: 0))
    }

    func testTranslateAndScale() {
        let a = Annotation(shape: .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)), color: .red, lineWidth: 6)
        XCTAssertEqual(a.translated(by: -10, 5).shape, .arrow(CGPoint(x: 0, y: 15), CGPoint(x: 40, y: 35)))
        let scaled = a.scaled(sx: 0.5, sy: 0.5)
        XCTAssertEqual(scaled.shape, .arrow(CGPoint(x: 5, y: 5), CGPoint(x: 25, y: 15)))
        XCTAssertEqual(scaled.lineWidth, 3)

        let text = Annotation(shape: .text(TextContent(string: "A", origin: CGPoint(x: 20, y: 40), fontSize: 30)), color: .red, lineWidth: 0)
        XCTAssertEqual(text.scaled(sx: 2, sy: 2).textContent, TextContent(string: "A", origin: CGPoint(x: 40, y: 80), fontSize: 60))
    }

    func testArrowHeadGeometry() {
        let g = ArrowGeometry.geometry(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 5)!
        XCTAssertEqual(g.tip, CGPoint(x: 100, y: 0))
        XCTAssertEqual(g.left.x, 80, accuracy: 0.001)
        XCTAssertEqual(g.left.y, -g.right.y, accuracy: 0.001)
        XCTAssertLessThan(g.shaftEnd.x, 100)
        XCTAssertNil(ArrowGeometry.geometry(from: .zero, to: CGPoint(x: 0.2, y: 0), lineWidth: 5))
    }
}

final class ImageRendererTests: XCTestCase {
    func testCropUsesTopLeftOrigin() {
        let image = TestImages.quadrants(width: 100, height: 80)
        let topLeft = ImageRenderer.crop(image, to: CGRect(x: 0, y: 0, width: 50, height: 40))!
        XCTAssertEqual(PixelSize(topLeft), PixelSize(width: 50, height: 40))
        XCTAssertTrue(TestImages.isRed(TestImages.pixel(topLeft, x: 25, y: 20)))

        let bottomRight = ImageRenderer.crop(image, to: CGRect(x: 50, y: 40, width: 50, height: 40))!
        XCTAssertTrue(TestImages.isBlue(TestImages.pixel(bottomRight, x: 25, y: 20)))
    }

    func testResizeProducesRequestedSizeAndKeepsLayout() {
        let image = TestImages.quadrants(width: 200, height: 100)
        let resized = ImageRenderer.resize(image, to: PixelSize(width: 100, height: 50))!
        XCTAssertEqual(PixelSize(resized), PixelSize(width: 100, height: 50))
        XCTAssertTrue(TestImages.isRed(TestImages.pixel(resized, x: 10, y: 10)))
        XCTAssertTrue(TestImages.isBlue(TestImages.pixel(resized, x: 90, y: 40)))
        XCTAssertNil(ImageRenderer.resize(image, to: PixelSize(width: 0, height: 50)))
    }

    func testRenderDrawsAnnotationsInTopLeftSpace() {
        let image = TestImages.solid(width: 100, height: 100)
        let rect = Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 30, height: 30)), color: .red, lineWidth: 4)
        let rendered = ImageRenderer.render(image, annotations: [rect])!
        XCTAssertTrue(TestImages.isRed(TestImages.pixel(rendered, x: 10, y: 25)), "left edge of the rectangle")
        XCTAssertTrue(TestImages.isWhite(TestImages.pixel(rendered, x: 25, y: 25)), "inside stays clear")
        XCTAssertTrue(TestImages.isWhite(TestImages.pixel(rendered, x: 10, y: 85)), "mirrored position untouched")
    }

    func testRenderWithoutAnnotationsReturnsSameImage() {
        let image = TestImages.solid(width: 10, height: 10)
        XCTAssertTrue(ImageRenderer.render(image, annotations: []) === image)
    }

    func testHighlighterIsTranslucent() {
        let image = TestImages.solid(width: 60, height: 60, color: .black)
        let mark = Annotation(shape: .highlighter([CGPoint(x: 0, y: 30), CGPoint(x: 60, y: 30)]), color: .yellow.withAlpha(0.4), lineWidth: 20)
        let p = TestImages.pixel(ImageRenderer.render(image, annotations: [mark])!, x: 30, y: 30)
        XCTAssertGreaterThan(p.r, 60, "yellow tint applied")
        XCTAssertLessThan(p.r, 200, "underlying content still shows through")
    }

    func testTextRendersPixels() {
        let image = TestImages.solid(width: 200, height: 80)
        let text = Annotation(shape: .text(TextContent(string: "WWW", origin: CGPoint(x: 10, y: 10), fontSize: 40)), color: .red, lineWidth: 0)
        let rendered = ImageRenderer.render(image, annotations: [text])!
        var redPixels = 0
        for x in stride(from: 10, to: 150, by: 2) {
            for y in stride(from: 10, to: 60, by: 2) where TestImages.isRed(TestImages.pixel(rendered, x: x, y: y)) {
                redPixels += 1
            }
        }
        XCTAssertGreaterThan(redPixels, 20)
        XCTAssertTrue(TestImages.isWhite(TestImages.pixel(rendered, x: 190, y: 75)))
    }

    func testThumbnailLimitsLongestEdge() {
        let thumb = ImageRenderer.thumbnail(of: TestImages.solid(width: 1000, height: 250), maxPixelSize: 200)!
        XCTAssertEqual(PixelSize(thumb), PixelSize(width: 200, height: 50))
    }
}
