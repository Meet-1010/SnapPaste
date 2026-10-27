import CoreGraphics

/// Integer pixel dimensions of a bitmap.
public struct PixelSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
    public var bounds: CGRect { CGRect(origin: .zero, size: cgSize) }
    public var pixelCount: Int { width * height }
    public var description: String { "\(width) × \(height)" }
}
