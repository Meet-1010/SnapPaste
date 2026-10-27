import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes images as PNG entirely in memory (no temporary files).
public enum PNGEncoder {
    public static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Prepares the exact bytes that go on the clipboard: annotations flattened, then PNG-encoded.
public enum ClipboardImagePreparer {
    public static func pngData(image: CGImage, annotations: [Annotation]) -> Data? {
        guard let flattened = ImageRenderer.render(image, annotations: annotations) else { return nil }
        return PNGEncoder.encode(flattened)
    }

    /// Same as `pngData`, but runs off the main thread.
    public static func pngDataInBackground(image: CGImage, annotations: [Annotation]) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            pngData(image: image, annotations: annotations)
        }.value
    }
}

/// Writes to a pasteboard. Production code uses `.general`; tests pass a private named pasteboard.
@MainActor
public struct ClipboardWriter {
    public let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Puts a lossless PNG on the pasteboard. PNG is read by browsers, Electron and native apps alike,
    /// so no second (much larger) TIFF copy is added.
    @discardableResult
    public func writePNG(_ data: Data) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }

    @discardableResult
    public func writeText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    public var changeCount: Int { pasteboard.changeCount }
}
