import AppKit
import SnapPasteCore

/// Puts images and text on the system clipboard. Encoding happens off the main thread and in memory.
final class ClipboardService {
    enum Outcome {
        case copied
        /// A newer copy request finished first; this one was dropped so the clipboard holds the latest image.
        case superseded
        case failed
    }

    private let writer = ClipboardWriter()
    private var generation = 0

    func copy(image: CGImage, annotations: [Annotation]) async -> Outcome {
        generation += 1
        let request = generation
        guard let data = await ClipboardImagePreparer.pngDataInBackground(image: image, annotations: annotations) else {
            return .failed
        }
        guard request == generation else { return .superseded }
        return writer.writePNG(data) ? .copied : .failed
    }

    @discardableResult
    func copyText(_ text: String) -> Bool {
        generation += 1
        return writer.writeText(text)
    }
}
