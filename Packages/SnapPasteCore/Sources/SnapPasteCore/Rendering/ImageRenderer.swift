import CoreGraphics

/// Bitmap operations on captured images. Everything happens in memory.
public enum ImageRenderer {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func makeContext(size: PixelSize, colorSpace: CGColorSpace? = nil) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        if let space = colorSpace, space.model == .rgb,
           let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) {
            return context
        }
        return CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)
    }

    /// Flattens annotations onto the image. Returns the original image when there is nothing to draw.
    public static func render(_ image: CGImage, annotations: [Annotation]) -> CGImage? {
        guard !annotations.isEmpty else { return image }
        let size = PixelSize(image)
        guard let context = makeContext(size: size, colorSpace: image.colorSpace) else { return nil }
        context.draw(image, in: size.bounds)
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        AnnotationDrawer.draw(annotations, in: context)
        return context.makeImage()
    }

    /// Crops to `rect` (image pixels, top-left origin). The result shares the source's pixel storage.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let r = CropMath.snapped(rect, within: PixelSize(image))
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    public static func resize(_ image: CGImage, to size: PixelSize) -> CGImage? {
        guard ResizeMath.validate(size) == nil,
              let context = makeContext(size: size, colorSpace: image.colorSpace) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: size.bounds)
        return context.makeImage()
    }

    /// A downscaled copy whose longest edge is at most `maxPixelSize`.
    public static func thumbnail(of image: CGImage, maxPixelSize: Int) -> CGImage? {
        let size = PixelSize(image)
        let longest = max(size.width, size.height)
        guard longest > maxPixelSize else { return image }
        return resize(image, to: ResizeMath.scaled(size, by: Double(maxPixelSize) / Double(longest)))
    }
}
