import AppKit
import XCTest
@testable import SnapPasteCore

final class OCRTextAssemblerTests: XCTestCase {
    func line(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat = 0.2, height: CGFloat = 0.04) -> RecognizedLine {
        RecognizedLine(text: text, boundingBox: CGRect(x: x, y: top - height, width: width, height: height))
    }

    func testOrdersTopToBottomAndLeftToRight() {
        let lines = [
            line("second", x: 0.1, top: 0.845),
            line("right", x: 0.32, top: 0.90),
            line("left", x: 0.1, top: 0.905),
        ]
        XCTAssertEqual(OCRTextAssembler.assemble(lines), "left right\nsecond")
    }

    func testSeparatesParagraphsAndColumns() {
        let lines = [
            line("Title", x: 0.1, top: 0.95),
            line("Body line", x: 0.1, top: 0.70),
            line("Name", x: 0.1, top: 0.50, width: 0.1),
            line("Value", x: 0.6, top: 0.50, width: 0.1),
        ]
        XCTAssertEqual(OCRTextAssembler.assemble(lines), "Title\n\nBody line\n\nName\tValue")
    }

    func testEmptyResults() {
        XCTAssertEqual(OCRTextAssembler.assemble([]), "")
        XCTAssertTrue(OCRResult(lines: [line("   ", x: 0, top: 1)]).isEmpty)
    }

    func testRecognizesRenderedText() async throws {
        let image = TestImages.solid(width: 900, height: 200)
        let text = Annotation(shape: .text(TextContent(string: "Hello SnapPaste 2026", origin: CGPoint(x: 30, y: 60), fontSize: 64)), color: .black, lineWidth: 0)
        let rendered = ImageRenderer.render(image, annotations: [text])!
        let result = try await TextRecognizer(languages: ["en-US"]).recognize(rendered)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.text.contains("Hello"), "recognized: \(result.text)")
        XCTAssertTrue(result.text.contains("2026"), "recognized: \(result.text)")
    }

    func testBlankImageHasNoText() async throws {
        let result = try await TextRecognizer().recognize(TestImages.solid(width: 300, height: 300))
        XCTAssertTrue(result.isEmpty)
    }

    func testRecognitionCanBeCancelled() async {
        let task = Task {
            try await TextRecognizer().recognize(TestImages.solid(width: 3000, height: 3000))
        }
        task.cancel()
        do {
            _ = try await task.value
            // Finishing before the cancel landed is acceptable; the call must simply not hang.
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
        }
    }
}

final class ShortcutTests: XCTestCase {
    let ctrlShift: KeyModifiers = [.control, .shift]

    func testDefaultsAreCompleteUniqueAndValid() {
        let config = ShortcutConfiguration.defaults
        let combos = ShortcutAction.allCases.compactMap { config[$0] }
        XCTAssertEqual(combos.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(combos).count, combos.count)
        let validator = ShortcutValidator()
        for action in ShortcutAction.allCases {
            XCTAssertNil(validator.issue(for: config[action]!, assigningTo: action, in: config), "\(action)")
        }
    }

    func testDefaultsAvoidSystemScreenshotShortcuts() {
        let system: Set<KeyCombo> = [
            KeyCombo(keyCode: 20, modifiers: [.command, .shift]),
            KeyCombo(keyCode: 21, modifiers: [.command, .shift]),
            KeyCombo(keyCode: 23, modifiers: [.command, .shift]),
            KeyCombo(keyCode: 21, modifiers: [.command, .shift, .control]),
        ]
        let config = ShortcutConfiguration.defaults
        for action in ShortcutAction.allCases {
            XCTAssertFalse(system.contains(config[action]!))
        }
    }

    func testValidatorIssues() {
        let config = ShortcutConfiguration.defaults
        let v = ShortcutValidator(systemShortcuts: [KeyCombo(keyCode: 21, modifiers: [.command, .shift])])
        XCTAssertEqual(v.issue(for: KeyCombo(keyCode: 21, modifiers: [.command, .shift]), assigningTo: .captureRegion, in: config), .conflictsWithSystem)
        XCTAssertEqual(v.issue(for: KeyCombo(keyCode: 8, modifiers: [.command]), assigningTo: .captureRegion, in: config), .reservedStandardShortcut)
        XCTAssertEqual(v.issue(for: KeyCombo(keyCode: 8, modifiers: [.option, .shift]), assigningTo: .captureRegion, in: config), .needsCommandOrControl)
        XCTAssertEqual(v.issue(for: KeyCombo(keyCode: 56, modifiers: [.control]), assigningTo: .captureRegion, in: config), .modifierOnly)
        XCTAssertEqual(v.issue(for: config[.extractText]!, assigningTo: .captureRegion, in: config), .duplicate(.extractText))
        XCTAssertNil(v.issue(for: config[.captureRegion]!, assigningTo: .captureRegion, in: config), "re-assigning the same combo is fine")
        XCTAssertNil(v.issue(for: KeyCombo(keyCode: 15, modifiers: [.control, .option]), assigningTo: .captureRegion, in: config))
    }

    func testConfigurationCodingKeepsClearedActionsAndFillsNewOnes() throws {
        var config = ShortcutConfiguration.defaults
        config[.openMenu] = nil
        config[.captureRegion] = KeyCombo(keyCode: 15, modifiers: [.control, .option])
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutConfiguration.self, from: data), config)

        // Simulate settings saved by an older version that didn't know about `extractText`.
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: ShortcutAction.extractText.rawValue)
        let old = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ShortcutConfiguration.self, from: old)
        XCTAssertNil(decoded[.openMenu])
        XCTAssertEqual(decoded[.extractText], ShortcutAction.extractText.defaultCombo)
    }

    func testModifierConversions() {
        let cocoa = NSEvent.ModifierFlags([.control, .shift, .command]).rawValue
        XCTAssertEqual(KeyModifiers(cocoaFlags: cocoa), [.control, .shift, .command])
        XCTAssertEqual(KeyModifiers([.option, .command]).cocoaFlags, NSEvent.ModifierFlags([.option, .command]).rawValue)
        // Symbolic hot key entries can carry Carbon's fn bit (1 << 17); it's ignored.
        XCTAssertEqual(KeyModifiers(rawValue: 4096 | 131072), [.control])
        XCTAssertEqual(KeyModifiers(rawValue: 768), [.command, .shift])
    }

    func testDisplayStrings() {
        XCTAssertEqual(ShortcutAction.captureRegion.defaultCombo.displayString(), "⌃⇧4")
        XCTAssertEqual(KeyCombo(keyCode: 49, modifiers: [.command, .option, .control, .shift]).displayString(), "⌃⌥⇧⌘Space")
        XCTAssertEqual(KeyCombo(keyCode: 122, modifiers: [.control]).displayString(), "⌃F1")
    }

    func testHotKeyIDsRoundTrip() {
        for action in ShortcutAction.allCases {
            XCTAssertEqual(ShortcutAction(hotKeyID: action.hotKeyID), action)
        }
        XCTAssertNil(ShortcutAction(hotKeyID: 0))
        XCTAssertNil(ShortcutAction(hotKeyID: 999))
    }
}
