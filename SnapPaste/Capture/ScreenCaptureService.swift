import AppKit
import ScreenCaptureKit
import SnapPasteCore

/// Takes single still images with ScreenCaptureKit. No stream is ever started.
final class ScreenCaptureService {
    func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Captures `rect` (display-local points, top-left origin) of a display, excluding SnapPaste's own windows.
    func captureRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications(in: content), exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let bounds = CGSize(width: display.width, height: display.height)
        let aligned = ScreenGeometry.pixelAligned(rect, scale: scale, within: bounds)
        let pixels = ScreenGeometry.pixelSize(of: aligned, scale: scale)
        guard pixels.width >= 1, pixels.height >= 1 else { throw CaptureFailure.selectionTooSmall }

        let configuration = Self.configuration(pixels: pixels)
        configuration.sourceRect = aligned
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications(in: content), exceptingWindows: [])
        let pixels = ScreenGeometry.pixelSize(of: filter.contentRect, scale: CGFloat(filter.pointPixelScale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: Self.configuration(pixels: pixels))
    }

    /// Captures one window by itself: overlapping windows and the desktop are not included.
    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }), window.isOnScreen else {
            throw CaptureFailure.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixels = ScreenGeometry.pixelSize(of: filter.contentRect, scale: CGFloat(filter.pointPixelScale))
        guard pixels.width >= 1, pixels.height >= 1 else { throw CaptureFailure.windowUnavailable }
        let configuration = Self.configuration(pixels: pixels)
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// IDs of windows ScreenCaptureKit is able to capture right now.
    func capturableWindowIDs() async throws -> Set<CGWindowID> {
        let content = try await shareableContent()
        return Set(content.windows.filter(\.isOnScreen).map(\.windowID))
    }

    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.applications.filter { $0.processID == pid }
    }

    private static func configuration(pixels: PixelSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // sRGB is what browsers and chat apps assume, so colors survive the paste unchanged.
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func containing(_ point: NSPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
