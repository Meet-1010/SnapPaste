import CoreGraphics

/// Coordinate conversions used by screen capture.
///
/// Cocoa global coordinates have their origin at the bottom-left of the primary display with y up.
/// Quartz (CGWindowList / ScreenCaptureKit) global coordinates have their origin at the top-left of
/// the primary display with y down. Both use points, not pixels.
public enum ScreenGeometry {
    /// Flips a rectangle vertically inside a container of the given height.
    /// Converts between Cocoa and Quartz global coordinates when `containerHeight` is the primary display height.
    public static func flipped(_ rect: CGRect, containerHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: containerHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a rect in Cocoa global coordinates to the local, top-left-origin point space of a screen.
    public static func localTopLeftRect(_ globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    /// Expands a selection (display-local points) to whole device pixels and clamps it to the display.
    public static func pixelAligned(_ rect: CGRect, scale: CGFloat, within bounds: CGSize) -> CGRect {
        let s = max(scale, 1)
        let r = rect.standardized.intersection(CGRect(origin: .zero, size: bounds))
        guard !r.isNull, r.width > 0, r.height > 0 else { return .zero }
        let minX = (r.minX * s).rounded(.down) / s
        let minY = (r.minY * s).rounded(.down) / s
        let maxX = (r.maxX * s).rounded(.up) / s
        let maxY = (r.maxY * s).rounded(.up) / s
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func pixelSize(of rect: CGRect, scale: CGFloat) -> PixelSize {
        PixelSize(width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()))
    }
}
