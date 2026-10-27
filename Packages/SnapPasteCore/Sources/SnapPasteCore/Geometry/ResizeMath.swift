import Foundation

public enum ResizeMath {
    /// Largest edge we allow; matches common GPU texture limits and keeps allocations bounded.
    public static let maxDimension = 16_384
    /// 100 MP ≈ 400 MB as an RGBA8 bitmap, the upper bound for a single resize allocation.
    public static let maxPixelCount = 100_000_000

    public enum Issue: Error, Equatable, Sendable {
        case notPositive
        case exceedsMaxDimension
        case exceedsMaxPixelCount

        public var message: String {
            switch self {
            case .notPositive: "Width and height must be at least 1 pixel."
            case .exceedsMaxDimension: "Width and height can't exceed \(ResizeMath.maxDimension) pixels."
            case .exceedsMaxPixelCount: "The image would be too large (over 100 megapixels)."
            }
        }
    }

    public static func height(forWidth width: Int, preservingAspectOf original: PixelSize) -> Int {
        guard original.width > 0 else { return max(1, original.height) }
        return max(1, Int((Double(width) * Double(original.height) / Double(original.width)).rounded()))
    }

    public static func width(forHeight height: Int, preservingAspectOf original: PixelSize) -> Int {
        guard original.height > 0 else { return max(1, original.width) }
        return max(1, Int((Double(height) * Double(original.width) / Double(original.height)).rounded()))
    }

    public static func scaled(_ original: PixelSize, by factor: Double) -> PixelSize {
        PixelSize(
            width: max(1, Int((Double(original.width) * factor).rounded())),
            height: max(1, Int((Double(original.height) * factor).rounded()))
        )
    }

    public static func validate(_ size: PixelSize) -> Issue? {
        if size.width < 1 || size.height < 1 { return .notPositive }
        if size.width > maxDimension || size.height > maxDimension { return .exceedsMaxDimension }
        let (count, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        if overflow || count > maxPixelCount { return .exceedsMaxPixelCount }
        return nil
    }
}
