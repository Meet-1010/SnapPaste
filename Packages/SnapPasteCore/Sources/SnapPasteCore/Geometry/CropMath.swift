import CoreGraphics

/// Crop rectangles live in image pixel space with a top-left origin.
public enum CropMath {
    /// Normalized rectangle spanned by two drag points, snapped to whole pixels and clamped to the image.
    public static func rect(from a: CGPoint, to b: CGPoint, within size: PixelSize) -> CGRect {
        let raw = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return snapped(raw, within: size)
    }

    /// Rounds the edges to whole pixels and clamps them to the image bounds. The result may be empty.
    public static func snapped(_ rect: CGRect, within size: PixelSize) -> CGRect {
        let r = rect.standardized
        let w = CGFloat(size.width), h = CGFloat(size.height)
        let minX = clamp(r.minX.rounded(), 0, w)
        let maxX = clamp(r.maxX.rounded(), 0, w)
        let minY = clamp(r.minY.rounded(), 0, h)
        let maxY = clamp(r.maxY.rounded(), 0, h)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// A crop is valid when it keeps at least one pixel in each direction.
    public static func isValid(_ rect: CGRect, within size: PixelSize) -> Bool {
        let s = snapped(rect, within: size)
        return s.width >= 1 && s.height >= 1
    }

    /// Whether applying the crop would change the image at all.
    public static func changesImage(_ rect: CGRect, within size: PixelSize) -> Bool {
        isValid(rect, within: size) && snapped(rect, within: size) != size.bounds
    }

    /// Moves a crop rectangle while keeping it fully inside the image.
    public static func moved(_ rect: CGRect, by dx: CGFloat, _ dy: CGFloat, within size: PixelSize) -> CGRect {
        var r = rect.standardized.offsetBy(dx: dx, dy: dy)
        r.origin.x = clamp(r.origin.x, 0, max(0, CGFloat(size.width) - r.width))
        r.origin.y = clamp(r.origin.y, 0, max(0, CGFloat(size.height) - r.height))
        return r
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}
