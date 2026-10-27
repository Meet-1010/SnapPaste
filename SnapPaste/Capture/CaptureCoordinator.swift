import AppKit
import SnapPasteCore

/// Runs one capture from permission check through selection to the final still image.
final class CaptureCoordinator {
    enum Kind {
        case region
        case window
        /// nil = the display under the pointer when there's only one, otherwise let the user pick.
        case screen(CGDirectDisplayID?)
    }

    private let service = ScreenCaptureService()
    private let overlay = SelectionOverlayController()
    private let permission: ScreenRecordingPermission
    private(set) var isBusy = false

    init(permission: ScreenRecordingPermission) {
        self.permission = permission
    }

    func capture(_ kind: Kind) async -> Result<CGImage, CaptureFailure> {
        guard !isBusy else { return .failure(.alreadyCapturing) }
        isBusy = true
        defer { isBusy = false }

        switch permission.checkBeforeCapture() {
        case .granted: break
        case .promptShown: return .failure(.cancelled)
        case .denied: return .failure(.permissionDenied)
        }

        do {
            switch kind {
            case .region:
                guard case .region(let rect, let displayID) = await overlay.run(.region) else { return .failure(.cancelled) }
                return .success(try await service.captureRegion(rect, displayID: displayID))

            case .window:
                let capturable = try await service.capturableWindowIDs()
                let candidates = WindowCandidate.onScreen(capturable: capturable)
                guard case .window(let candidate) = await overlay.run(.window(candidates)) else { return .failure(.cancelled) }
                return .success(try await service.captureWindow(candidate.id))

            case .screen(let requested):
                let displayID: CGDirectDisplayID
                if let requested {
                    displayID = requested
                } else if NSScreen.screens.count > 1 {
                    guard case .display(let picked) = await overlay.run(.display) else { return .failure(.cancelled) }
                    displayID = picked
                } else if let only = NSScreen.screens.first?.displayID {
                    displayID = only
                } else {
                    return .failure(.displayUnavailable)
                }
                return .success(try await service.captureDisplay(displayID))
            }
        } catch {
            let failure = CaptureFailure.classify(error)
            if failure == .permissionDenied { permission.refresh() }
            return .failure(failure)
        }
    }
}
