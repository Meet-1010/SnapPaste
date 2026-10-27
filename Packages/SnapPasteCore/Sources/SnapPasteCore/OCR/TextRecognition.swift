import CoreGraphics
import Foundation
import Vision

public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    /// Normalized bounding box in Vision's space: origin at the bottom-left, 0...1.
    public var boundingBox: CGRect
    public var confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float = 1) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public struct OCRResult: Equatable, Sendable {
    public var lines: [RecognizedLine]
    public var text: String

    public init(lines: [RecognizedLine]) {
        self.lines = lines
        self.text = OCRTextAssembler.assemble(lines)
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Turns Vision's line observations into readable text: top-to-bottom rows, left-to-right within a
/// row, and a blank line where a large vertical gap suggests a new paragraph.
public enum OCRTextAssembler {
    public static func assemble(_ lines: [RecognizedLine]) -> String {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return "" }

        let sorted = usable.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first, sameRow(anchor, line) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        let heights = sorted.map(\.boundingBox.height).sorted()
        let medianHeight = heights[heights.count / 2]

        var output = ""
        var previousRowBottom: CGFloat?
        for row in rows {
            let ordered = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let top = ordered.map(\.boundingBox.maxY).max() ?? 0
            if let bottom = previousRowBottom {
                output += (bottom - top) > medianHeight * 1.2 ? "\n\n" : "\n"
            }
            output += join(ordered, medianHeight: medianHeight)
            previousRowBottom = ordered.map(\.boundingBox.minY).min() ?? 0
        }
        return output
    }

    /// Two lines share a row when they overlap vertically by at least half the shorter line's height.
    static func sameRow(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        let overlap = min(a.boundingBox.maxY, b.boundingBox.maxY) - max(a.boundingBox.minY, b.boundingBox.minY)
        return overlap >= min(a.boundingBox.height, b.boundingBox.height) * 0.5
    }

    /// Words close together get a space; distant columns get a tab so tables stay aligned when pasted.
    static func join(_ row: [RecognizedLine], medianHeight: CGFloat) -> String {
        var result = ""
        var previous: RecognizedLine?
        for line in row {
            if let previous {
                let gap = line.boundingBox.minX - previous.boundingBox.maxX
                result += gap > medianHeight * 2 ? "\t" : " "
            }
            result += line.text.trimmingCharacters(in: .whitespaces)
            previous = line
        }
        return result
    }
}

public enum OCRError: Error, Equatable, Sendable {
    case failed(String)

    public var message: String {
        switch self {
        case .failed(let detail): "Text recognition failed: \(detail)"
        }
    }
}

/// Local text recognition with Apple's Vision framework. Images never leave the Mac.
public struct TextRecognizer: Sendable {
    /// BCP-47 codes in priority order. Empty means automatic language detection.
    public var languages: [String]
    public var usesLanguageCorrection: Bool

    public init(languages: [String] = ["en-US"], usesLanguageCorrection: Bool = true) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognize(_ image: CGImage) async throws -> OCRResult {
        let job = RecognitionJob(image: image, languages: languages, usesLanguageCorrection: usesLanguageCorrection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: job.run())
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Languages supported by the accurate recognizer on this Mac.
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }
}

/// Owns the non-Sendable Vision objects for one recognition so they can be cancelled from another thread.
private final class RecognitionJob: @unchecked Sendable {
    private let image: CGImage
    private let request: VNRecognizeTextRequest
    private let lock = NSLock()
    private var cancelled = false

    init(image: CGImage, languages: [String], usesLanguageCorrection: Bool) {
        self.image = image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        self.request = request
    }

    func cancel() {
        lock.withLock { cancelled = true }
        request.cancel()
    }

    func run() -> Result<OCRResult, Error> {
        if lock.withLock({ cancelled }) { return .failure(CancellationError()) }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if lock.withLock({ cancelled }) { return .failure(CancellationError()) }
            return .failure(OCRError.failed(error.localizedDescription))
        }
        if lock.withLock({ cancelled }) { return .failure(CancellationError()) }
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, boundingBox: observation.boundingBox, confidence: candidate.confidence)
        }
        return .success(OCRResult(lines: lines))
    }
}
