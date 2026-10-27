import AppKit
import ScreenCaptureKit
import XCTest
@testable import SnapPasteCore

@MainActor
final class ClipboardTests: XCTestCase {
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("SnapPasteTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    func testPNGRoundTrip() {
        let image = TestImages.quadrants(width: 64, height: 32)
        let data = PNGEncoder.encode(image)!
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
        let decoded = PNGEncoder.decode(data)!
        XCTAssertEqual(PixelSize(decoded), PixelSize(width: 64, height: 32))
        XCTAssertTrue(TestImages.isRed(TestImages.pixel(decoded, x: 5, y: 5)))
    }

    func testWritesPNGToPasteboard() {
        let writer = ClipboardWriter(pasteboard: pasteboard)
        let data = PNGEncoder.encode(TestImages.solid(width: 8, height: 8))!
        XCTAssertTrue(writer.writePNG(data))
        // Only PNG is written; the pasteboard server derives TIFF on demand for apps that ask for it.
        XCTAssertEqual(pasteboard.types?.first, .png)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        // NSImage can read it back, the same path most native apps use when pasting.
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testWritesExtractedText() {
        let writer = ClipboardWriter(pasteboard: pasteboard)
        XCTAssertTrue(writer.writeText("Hello\nWorld"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello\nWorld")
    }

    func testQuickCopyUsesUneditedCapture() async {
        let capture = TestImages.solid(width: 40, height: 30)
        let data = await ClipboardImagePreparer.pngDataInBackground(image: capture, annotations: [])!
        let decoded = PNGEncoder.decode(data)!
        XCTAssertEqual(PixelSize(decoded), PixelSize(width: 40, height: 30))
        XCTAssertTrue(TestImages.isWhite(TestImages.pixel(decoded, x: 20, y: 15)))
    }

    func testEditedCopyIncludesAnnotationsAndTransforms() async throws {
        let doc = EditorDocument(image: TestImages.solid(width: 400, height: 300))
        doc.add(Annotation(shape: .pen([CGPoint(x: 100, y: 150), CGPoint(x: 300, y: 150)]), color: .red, lineWidth: 10))
        doc.crop(to: CGRect(x: 50, y: 50, width: 300, height: 200))
        try doc.resize(to: PixelSize(width: 150, height: 100))

        let data = await ClipboardImagePreparer.pngDataInBackground(image: doc.image, annotations: doc.annotations)!
        let writer = ClipboardWriter(pasteboard: pasteboard)
        writer.writePNG(data)

        let pasted = PNGEncoder.decode(pasteboard.data(forType: .png)!)!
        XCTAssertEqual(PixelSize(pasted), PixelSize(width: 150, height: 100))
        // The stroke at y=150 in the original is y=(150-50)/2=50 after crop and resize.
        XCTAssertTrue(TestImages.isRed(TestImages.pixel(pasted, x: 75, y: 50)))
        XCTAssertTrue(TestImages.isWhite(TestImages.pixel(pasted, x: 75, y: 20)))
    }

    func testPreparingClipboardImageWritesNoFiles() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        let doc = EditorDocument(image: TestImages.solid(width: 300, height: 300))
        doc.add(Annotation(shape: .text(TextContent(string: "No files", origin: CGPoint(x: 10, y: 10), fontSize: 30)), color: .red, lineWidth: 0))
        let data = await ClipboardImagePreparer.pngDataInBackground(image: doc.image, annotations: doc.annotations)
        XCTAssertNotNil(data)
        ClipboardWriter(pasteboard: pasteboard).writePNG(data!)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        XCTAssertTrue(after.subtracting(before).filter { $0.lowercased().hasSuffix(".png") || $0.lowercased().hasSuffix(".tiff") }.isEmpty)
    }
}

@MainActor
final class CaptureStoreTests: XCTestCase {
    func testReplaceAndClearReleaseDocument() {
        let store = CaptureStore()
        XCTAssertFalse(store.hasCapture)
        weak var weakDocument: EditorDocument?
        autoreleasepool {
            let doc = store.replace(with: TestImages.solid(width: 10, height: 10))
            weakDocument = doc
        }
        XCTAssertTrue(store.hasCapture)
        XCTAssertNotNil(weakDocument)
        store.clear()
        XCTAssertFalse(store.hasCapture)
        XCTAssertNil(weakDocument, "no lingering reference keeps screenshot pixels alive")
    }

    func testNewCaptureReplacesPreviousOne() {
        let store = CaptureStore()
        weak var first: EditorDocument?
        autoreleasepool { first = store.replace(with: TestImages.solid(width: 10, height: 10)) }
        let second = store.replace(with: TestImages.solid(width: 20, height: 20))
        XCTAssertTrue(store.document === second)
        XCTAssertNil(first)
    }

    func testCancelledCaptureLeavesStateUntouched() {
        // A cancelled capture never reaches `replace`, so the previous capture and its edits survive.
        let store = CaptureStore()
        let doc = store.replace(with: TestImages.solid(width: 10, height: 10))
        doc.add(Annotation(shape: .line(.zero, CGPoint(x: 5, y: 5)), color: .red, lineWidth: 1))
        let failure = CaptureFailure.classify(CancellationError())
        XCTAssertEqual(failure, .cancelled)
        XCTAssertTrue(store.document === doc)
        XCTAssertEqual(store.document?.annotations.count, 1)
    }

    func testPostCaptureActionResolution() {
        XCTAssertEqual(PostCaptureAction.resolve(quickCopy: true, openEditorAfterCapture: false), .copy)
        XCTAssertEqual(PostCaptureAction.resolve(quickCopy: true, openEditorAfterCapture: true), .copyAndOpenEditor)
        XCTAssertEqual(PostCaptureAction.resolve(quickCopy: false, openEditorAfterCapture: false), .openEditor)
        XCTAssertEqual(PostCaptureAction.resolve(quickCopy: false, openEditorAfterCapture: true), .openEditor)
        XCTAssertFalse(PostCaptureAction.openEditor.copiesImmediately)
    }

    func testPermissionErrorsAreClassified() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertEqual(CaptureFailure.classify(declined), .permissionDenied)
        let other = NSError(domain: "Other", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        XCTAssertEqual(CaptureFailure.classify(other), .failed("Boom"))
        XCTAssertEqual(CaptureFailure.classify(CaptureFailure.windowUnavailable), .windowUnavailable)
    }
}
