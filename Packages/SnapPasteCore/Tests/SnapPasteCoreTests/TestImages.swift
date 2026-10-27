import CoreGraphics
@testable import SnapPasteCore

enum TestImages {
    /// A solid-color sRGB image.
    static func solid(width: Int, height: Int, color: RGBAColor = .white) -> CGImage {
        let context = ImageRenderer.makeContext(size: PixelSize(width: width, height: height))!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// White image whose top-left quadrant is red and bottom-right quadrant is blue
    /// (quadrants named in top-left-origin image space).
    static func quadrants(width: Int, height: Int) -> CGImage {
        let context = ImageRenderer.makeContext(size: PixelSize(width: width, height: height))!
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so the fills below use top-left coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: height / 2, width: width - width / 2, height: height - height / 2))
        return context.makeImage()!
    }

    /// RGBA (0–255) of the pixel at (x, y), y measured from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: ImageRenderer.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        // Row 0 of a bitmap context's memory is the top of the image.
        let offset = y * image.width * 4 + x * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3]))
    }

    static func isRed(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 200 && p.g < 80 && p.b < 80 }
    static func isBlue(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.b > 200 && p.r < 80 && p.g < 80 }
    static func isWhite(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 240 && p.g > 240 && p.b > 240 }
}
