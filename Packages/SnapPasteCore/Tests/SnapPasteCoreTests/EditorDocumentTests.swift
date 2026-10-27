import CoreGraphics
import XCTest
@testable import SnapPasteCore

final class EditHistoryTests: XCTestCase {
    func testUndoRedoOrder() {
        var history = EditHistory<Int>()
        history.record(previous: 0, actionName: "A")
        history.record(previous: 1, actionName: "B")
        XCTAssertEqual(history.undo(current: 2), 1)
        XCTAssertEqual(history.undo(current: 1), 0)
        XCTAssertNil(history.undo(current: 0))
        XCTAssertEqual(history.redo(current: 0), 1)
        XCTAssertEqual(history.redo(current: 1), 2)
        XCTAssertFalse(history.canRedo)
    }

    func testNewChangeClearsRedo() {
        var history = EditHistory<Int>()
        history.record(previous: 0, actionName: "A")
        _ = history.undo(current: 1)
        XCTAssertTrue(history.canRedo)
        history.record(previous: 0, actionName: "B")
        XCTAssertFalse(history.canRedo)
    }

    func testCoalescingAndLimit() {
        var history = EditHistory<Int>(limit: 3)
        history.record(previous: 0, actionName: "Width", coalescingKey: "w")
        history.record(previous: 1, actionName: "Width", coalescingKey: "w")
        history.record(previous: 2, actionName: "Width", coalescingKey: "w")
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertEqual(history.undo(current: 3), 0, "one undo reverts the whole slider drag")

        for i in 0..<10 { history.record(previous: i, actionName: "X") }
        XCTAssertEqual(history.undoStack.count, 3)
        XCTAssertEqual(history.undoStack.first?.state, 7)
    }
}

@MainActor
final class EditorDocumentTests: XCTestCase {
    func makeAnnotation(_ x: CGFloat = 10) -> Annotation {
        Annotation(shape: .rectangle(CGRect(x: x, y: x, width: 20, height: 20)), color: .red, lineWidth: 2)
    }

    func testAddUndoRedo() {
        let doc = EditorDocument(image: TestImages.solid(width: 100, height: 100))
        var changes = 0
        doc.onChange = { changes += 1 }
        doc.add(makeAnnotation())
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertTrue(doc.canUndo)
        doc.undo()
        XCTAssertEqual(doc.annotations.count, 0)
        XCTAssertTrue(doc.canRedo)
        doc.redo()
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertEqual(changes, 3)
    }

    func testNoOpChangesAreNotRecorded() {
        let doc = EditorDocument(image: TestImages.solid(width: 100, height: 100))
        XCTAssertFalse(doc.removeAnnotations(withIDs: [UUID()]))
        XCTAssertFalse(doc.crop(to: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertFalse(doc.canUndo)
    }

    func testEraseRemovesOnlyAnnotationsAndIsUndoable() {
        let image = TestImages.solid(width: 100, height: 100)
        let doc = EditorDocument(image: image)
        let a = makeAnnotation(10), b = makeAnnotation(50)
        doc.add(a)
        doc.add(b)
        doc.removeAnnotations(withIDs: [a.id])
        XCTAssertEqual(doc.annotations.map(\.id), [b.id])
        XCTAssertTrue(doc.image === image, "erasing never touches the captured pixels")
        doc.undo()
        XCTAssertEqual(doc.annotations.map(\.id), [a.id, b.id])
    }

    func testCropMovesAnnotationsAndUndoRestoresOriginalImage() {
        let image = TestImages.quadrants(width: 200, height: 100)
        let doc = EditorDocument(image: image)
        let inside = makeAnnotation(60)
        let outside = makeAnnotation(0)
        doc.add(inside)
        doc.add(outside)
        XCTAssertTrue(doc.crop(to: CGRect(x: 50, y: 25, width: 100, height: 50)))
        XCTAssertEqual(doc.pixelSize, PixelSize(width: 100, height: 50))
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertEqual(doc.annotations.first?.shape, .rectangle(CGRect(x: 10, y: 35, width: 20, height: 20)))
        XCTAssertEqual(doc.undoActionName, "Crop")
        doc.undo()
        XCTAssertTrue(doc.image === image)
        XCTAssertEqual(doc.annotations.count, 2)
    }

    func testResizeScalesAnnotationsAndValidates() throws {
        let doc = EditorDocument(image: TestImages.solid(width: 200, height: 100))
        doc.add(makeAnnotation(20))
        try doc.resize(to: PixelSize(width: 100, height: 50))
        XCTAssertEqual(doc.pixelSize, PixelSize(width: 100, height: 50))
        XCTAssertEqual(doc.annotations.first?.shape, .rectangle(CGRect(x: 10, y: 10, width: 10, height: 10)))
        XCTAssertThrowsError(try doc.resize(to: PixelSize(width: 0, height: 10)))
        XCTAssertThrowsError(try doc.resize(to: PixelSize(width: 30_000, height: 10)))
        doc.undo()
        XCTAssertEqual(doc.pixelSize, PixelSize(width: 200, height: 100))
    }

    func testResetIsUndoable() throws {
        let image = TestImages.solid(width: 100, height: 100)
        let doc = EditorDocument(image: image)
        doc.add(makeAnnotation())
        try doc.resize(to: PixelSize(width: 50, height: 50))
        doc.resetToOriginal()
        XCTAssertTrue(doc.image === image)
        XCTAssertTrue(doc.annotations.isEmpty)
        XCTAssertFalse(doc.hasEdits)
        doc.undo()
        XCTAssertEqual(doc.pixelSize, PixelSize(width: 50, height: 50))
        XCTAssertTrue(doc.hasEdits)
    }

    func testUpdateWithCoalescingCreatesSingleUndoStep() {
        let doc = EditorDocument(image: TestImages.solid(width: 100, height: 100))
        var a = makeAnnotation()
        doc.add(a)
        for width in [3.0, 4.0, 5.0, 6.0] {
            a.lineWidth = width
            doc.update(a, actionName: "Change Thickness", coalescingKey: "thickness-\(a.id)")
        }
        XCTAssertEqual(doc.annotations.first?.lineWidth, 6)
        doc.undo()
        XCTAssertEqual(doc.annotations.first?.lineWidth, 2)
    }

    func testRenderedImageIncludesAnnotationsAndCrop() {
        let doc = EditorDocument(image: TestImages.solid(width: 200, height: 200))
        doc.add(Annotation(shape: .rectangle(CGRect(x: 110, y: 110, width: 40, height: 40)), color: .red, lineWidth: 6))
        doc.crop(to: CGRect(x: 100, y: 100, width: 100, height: 100))
        let output = doc.renderedImage()!
        XCTAssertEqual(PixelSize(output), PixelSize(width: 100, height: 100))
        XCTAssertTrue(TestImages.isRed(TestImages.pixel(output, x: 10, y: 30)))
        XCTAssertTrue(TestImages.isWhite(TestImages.pixel(output, x: 30, y: 30)))
    }
}
