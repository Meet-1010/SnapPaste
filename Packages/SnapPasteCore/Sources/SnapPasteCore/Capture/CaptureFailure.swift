import Foundation
import ScreenCaptureKit

public enum CaptureFailure: Error, Equatable, Sendable {
    case cancelled
    case permissionDenied
    case displayUnavailable
    case windowUnavailable
    case selectionTooSmall
    case alreadyCapturing
    case failed(String)

    public var message: String {
        switch self {
        case .cancelled: "Capture cancelled."
        case .permissionDenied: "SnapPaste needs Screen Recording permission to capture the screen."
        case .displayUnavailable: "That display is no longer available."
        case .windowUnavailable: "That window can't be captured. It may have closed, be minimized, or be protected."
        case .selectionTooSmall: "The selection is too small to capture."
        case .alreadyCapturing: "A capture is already in progress."
        case .failed(let detail): "The capture failed: \(detail)"
        }
    }

    /// Maps errors thrown by ScreenCaptureKit to user-facing failures.
    public static func classify(_ error: Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch SCStreamError.Code(rawValue: nsError.code) {
            case .userDeclined?: return .permissionDenied
            case .noDisplayList?, .missingEntitlements?: return .permissionDenied
            case .noCaptureSource?: return .windowUnavailable
            case .userStopped?: return .cancelled
            default: break
            }
        }
        return .failed(nsError.localizedDescription)
    }
}
