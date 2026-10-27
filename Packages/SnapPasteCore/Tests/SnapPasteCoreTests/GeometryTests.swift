import CoreGraphics
import XCTest
@testable import SnapPasteCore

final class CropMathTests: XCTestCase {
    let size = PixelSize(width: 200, height: 100)

    func testRectFromReversedDragIsNormalized() {
        let r = CropMath.rect(from: CGPoint(x: 150, y: 80), to: CGPoint(x: 50, y: 20), within: size)
        XCTAssertEqual(r, CGRect(x: 50, y: 20, width: 100, height: 60))
    }

    func testRectIsSnappedToWholePixels() {
        let r = CropMath.rect(from: CGPoint(x: 10.4, y: 10.6), to: CGPoint(x: 20.5, y: 30.2), within: size)
        XCTAssertEqual(r, CGRect(x: 10, y: 11, width: 11, height: 19))
    }

    func testRectIsClampedToImage() {
        let r = CropMath.rect(from: CGPoint(x: -40, y: -10), to: CGPoint(x: 500, y: 60), within: size)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 200, height: 60))
    }

    func testValidity() {
        XCTAssertFalse(CropMath.isValid(CGRect(x: 10, y: 10, width: 0.2, height: 50), within: size))
        XCTAssertFalse(CropMath.isValid(CGRect(x: 300, y: 10, width: 20, height: 20), within: size))
        XCTAssertTrue(CropMath.isValid(CGRect(x: 10, y: 10, width: 1, height: 1), within: size))
        XCTAssertFalse(CropMath.changesImage(size.bounds, within: size))
        XCTAssertTrue(CropMath.changesImage(CGRect(x: 0, y: 0, width: 199, height: 100), within: size))
    }

    func testMovingKeepsRectInsideImage() {
        let r = CGRect(x: 150, y: 50, width: 40, height: 40)
        XCTAssertEqual(CropMath.moved(r, by: 100, 100, within: size), CGRect(x: 160, y: 60, width: 40, height: 40))
        XCTAssertEqual(CropMath.moved(r, by: -500, -500, within: size), CGRect(x: 0, y: 0, width: 40, height: 40))
    }
}

final class ResizeMathTests: XCTestCase {
    func testAspectPreservingHeight() {
        let original = PixelSize(width: 1920, height: 1080)
        XCTAssertEqual(ResizeMath.height(forWidth: 960, preservingAspectOf: original), 540)
        XCTAssertEqual(ResizeMath.height(forWidth: 1000, preservingAspectOf: original), 563) // 562.5 rounds up
        XCTAssertEqual(ResizeMath.width(forHeight: 720, preservingAspectOf: original), 1280)
    }

    func testAspectNeverProducesZero() {
        let wide = PixelSize(width: 4000, height: 10)
        XCTAssertEqual(ResizeMath.height(forWidth: 10, preservingAspectOf: wide), 1)
    }

    func testPercentScaling() {
        XCTAssertEqual(ResizeMath.scaled(PixelSize(width: 2880, height: 1800), by: 0.5), PixelSize(width: 1440, height: 900))
        XCTAssertEqual(ResizeMath.scaled(PixelSize(width: 3, height: 3), by: 0.01), PixelSize(width: 1, height: 1))
    }

    func testValidationRejectsInvalidAndExcessiveSizes() {
        XCTAssertNil(ResizeMath.validate(PixelSize(width: 1, height: 1)))
        XCTAssertNil(ResizeMath.validate(PixelSize(width: 8000, height: 8000)))
        XCTAssertEqual(ResizeMath.validate(PixelSize(width: 0, height: 10)), .notPositive)
        XCTAssertEqual(ResizeMath.validate(PixelSize(width: -5, height: 10)), .notPositive)
        XCTAssertEqual(ResizeMath.validate(PixelSize(width: 20_000, height: 10)), .exceedsMaxDimension)
        XCTAssertEqual(ResizeMath.validate(PixelSize(width: 16_000, height: 16_000)), .exceedsMaxPixelCount)
    }
}

final class ViewportTransformTests: XCTestCase {
    func testFitCentersAndScalesDown() {
        let t = ViewportTransform.fit(imageSize: CGSize(width: 2000, height: 1000), in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(t.zoom, 0.5, accuracy: 0.0001)
        XCTAssertEqual(t.offset, CGPoint(x: 0, y: 150))
    }

    func testFitRespectsMaxZoom() {
        let t = ViewportTransform.fit(imageSize: CGSize(width: 100, height: 100), in: CGSize(width: 1000, height: 1000), maxZoom: 0.5)
        XCTAssertEqual(t.zoom, 0.5)
        XCTAssertEqual(t.offset, CGPoint(x: 475, y: 475))
    }

    func testRoundTripMapping() {
        let t = ViewportTransform(zoom: 0.37, offset: CGPoint(x: 12, y: -40))
        let p = CGPoint(x: 1234.5, y: 678.25)
        let back = t.viewToImage(t.imageToView(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        let r = CGRect(x: 10, y: 20, width: 300, height: 400)
        let viewRect = t.imageToView(r)
        XCTAssertEqual(viewRect.width, 111, accuracy: 1e-9)
        XCTAssertEqual(t.viewToImage(viewRect).minY, 20, accuracy: 1e-9)
    }

    func testZoomKeepsAnchorFixed() {
        let t = ViewportTransform(zoom: 0.5, offset: CGPoint(x: 100, y: 50))
        let anchor = CGPoint(x: 300, y: 200)
        let before = t.viewToImage(anchor)
        let zoomed = t.zoomed(to: 2, anchor: anchor)
        let after = zoomed.viewToImage(anchor)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        XCTAssertEqual(zoomed.zoom, 2)
    }

    func testClampingCentersSmallImagesAndKeepsLargeOnesCovering() {
        let small = ViewportTransform(zoom: 1, offset: CGPoint(x: -300, y: 900))
            .clamped(imageSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 500, height: 500))
        XCTAssertEqual(small.offset, CGPoint(x: 200, y: 200))

        let large = ViewportTransform(zoom: 1, offset: CGPoint(x: 100, y: -5000))
            .clamped(imageSize: CGSize(width: 2000, height: 2000), viewSize: CGSize(width: 500, height: 500))
        XCTAssertEqual(large.offset, CGPoint(x: 0, y: -1500))
    }
}

final class ScreenGeometryTests: XCTestCase {
    func testFlipBetweenCocoaAndQuartzIsSymmetric() {
        let quartz = CGRect(x: 100, y: 50, width: 400, height: 300)
        let cocoa = ScreenGeometry.flipped(quartz, containerHeight: 1080)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 730, width: 400, height: 300))
        XCTAssertEqual(ScreenGeometry.flipped(cocoa, containerHeight: 1080), quartz)
    }

    func testLocalRectOnSecondaryDisplay() {
        // A display to the right of a 1440×900 primary, offset 100pt down.
        let screen = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        let window = CGRect(x: 1540, y: 680, width: 200, height: 100)
        XCTAssertEqual(ScreenGeometry.localTopLeftRect(window, screenFrame: screen), CGRect(x: 100, y: 200, width: 200, height: 100))
    }

    func testPixelAlignmentOnRetina() {
        let r = ScreenGeometry.pixelAligned(CGRect(x: 10.3, y: 20.8, width: 100.1, height: 50.1), scale: 2, within: CGSize(width: 1440, height: 900))
        XCTAssertEqual(r, CGRect(x: 10, y: 20.5, width: 100.5, height: 50.5))
        XCTAssertEqual(ScreenGeometry.pixelSize(of: r, scale: 2), PixelSize(width: 201, height: 101))
    }

    func testPixelAlignmentClampsToDisplay() {
        let r = ScreenGeometry.pixelAligned(CGRect(x: -20, y: 880, width: 100, height: 100), scale: 2, within: CGSize(width: 1440, height: 900))
        XCTAssertEqual(r, CGRect(x: 0, y: 880, width: 80, height: 20))
        XCTAssertEqual(ScreenGeometry.pixelAligned(CGRect(x: 2000, y: 0, width: 10, height: 10), scale: 2, within: CGSize(width: 1440, height: 900)), .zero)
    }
}
