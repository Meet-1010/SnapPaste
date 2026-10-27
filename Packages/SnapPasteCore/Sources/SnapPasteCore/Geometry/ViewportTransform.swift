import CoreGraphics

/// Maps image pixel coordinates (top-left origin) to coordinates of a flipped view (top-left origin).
public struct ViewportTransform: Equatable, Sendable {
    /// View points per image pixel.
    public var zoom: CGFloat
    /// Position of the image's top-left corner in view coordinates.
    public var offset: CGPoint

    public static let minZoom: CGFloat = 0.02
    public static let maxZoom: CGFloat = 32

    public static let identity = ViewportTransform(zoom: 1, offset: .zero)

    public init(zoom: CGFloat, offset: CGPoint) {
        self.zoom = zoom
        self.offset = offset
    }

    public func imageToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + p.x * zoom, y: offset.y + p.y * zoom)
    }

    public func viewToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }

    public func imageToView(_ r: CGRect) -> CGRect {
        let o = imageToView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    public func viewToImage(_ r: CGRect) -> CGRect {
        let o = viewToImage(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width / zoom, height: r.height / zoom)
    }

    /// Scales the image to fit inside the view (never above `maxZoom`) and centers it.
    public static func fit(imageSize: CGSize, in viewSize: CGSize, padding: CGFloat = 0, maxZoom: CGFloat = .greatestFiniteMagnitude) -> ViewportTransform {
        guard imageSize.width > 0, imageSize.height > 0 else { return .identity }
        let availableWidth = max(1, viewSize.width - padding * 2)
        let availableHeight = max(1, viewSize.height - padding * 2)
        let zoom = max(minZoom, min(availableWidth / imageSize.width, availableHeight / imageSize.height, maxZoom))
        let offset = CGPoint(
            x: ((viewSize.width - imageSize.width * zoom) / 2).rounded(),
            y: ((viewSize.height - imageSize.height * zoom) / 2).rounded()
        )
        return ViewportTransform(zoom: zoom, offset: offset)
    }

    /// Changes the zoom while keeping the image point under `anchor` (a view point) fixed.
    public func zoomed(to newZoom: CGFloat, anchor: CGPoint) -> ViewportTransform {
        let z = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let imagePoint = viewToImage(anchor)
        return ViewportTransform(zoom: z, offset: CGPoint(x: anchor.x - imagePoint.x * z, y: anchor.y - imagePoint.y * z))
    }

    /// Centers the image on axes where it is smaller than the view, otherwise keeps the view covered.
    public func clamped(imageSize: CGSize, viewSize: CGSize, padding: CGFloat = 0) -> ViewportTransform {
        func axis(_ offset: CGFloat, _ content: CGFloat, _ view: CGFloat) -> CGFloat {
            if content + padding * 2 <= view { return ((view - content) / 2).rounded() }
            return min(padding, max(view - content - padding, offset))
        }
        return ViewportTransform(zoom: zoom, offset: CGPoint(
            x: axis(offset.x, imageSize.width * zoom, viewSize.width),
            y: axis(offset.y, imageSize.height * zoom, viewSize.height)
        ))
    }
}
