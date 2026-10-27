import CoreGraphics
import Foundation
import Observation

/// Holds the most recent capture in memory, and only in memory.
@MainActor
@Observable
public final class CaptureStore {
    public private(set) var document: EditorDocument?
    public private(set) var capturedAt: Date?

    public init() {}

    public var hasCapture: Bool { document != nil }

    /// Replaces the current capture. The previous document (and its undo history) is released.
    @discardableResult
    public func replace(with image: CGImage, at date: Date = Date()) -> EditorDocument {
        let document = EditorDocument(image: image)
        self.document = document
        capturedAt = date
        return document
    }

    /// Drops the capture so its pixel buffers can be freed.
    public func clear() {
        document = nil
        capturedAt = nil
    }
}

/// What happens right after a successful capture.
public enum PostCaptureAction: Equatable, Sendable {
    case copy
    case openEditor
    case copyAndOpenEditor

    public var copiesImmediately: Bool { self != .openEditor }
    public var opensEditor: Bool { self != .copy }

    /// Quick Copy off always means "edit first", so a capture is never left with nowhere to go.
    public static func resolve(quickCopy: Bool, openEditorAfterCapture: Bool) -> PostCaptureAction {
        switch (quickCopy, openEditorAfterCapture) {
        case (true, true): .copyAndOpenEditor
        case (true, false): .copy
        case (false, _): .openEditor
        }
    }
}
