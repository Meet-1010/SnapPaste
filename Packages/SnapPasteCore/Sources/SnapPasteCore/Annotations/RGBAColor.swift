import CoreGraphics

/// An sRGB color that can be persisted in settings and used from any thread.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Same color ignoring alpha.
    public func isSameHue(as other: RGBAColor) -> Bool {
        abs(red - other.red) < 0.002 && abs(green - other.green) < 0.002 && abs(blue - other.blue) < 0.002
    }

    public static let red = RGBAColor(hex: 0xFF3B30)
    public static let orange = RGBAColor(hex: 0xFF9500)
    public static let yellow = RGBAColor(hex: 0xFFD60A)
    public static let green = RGBAColor(hex: 0x34C759)
    public static let blue = RGBAColor(hex: 0x0A84FF)
    public static let purple = RGBAColor(hex: 0xBF5AF2)
    public static let black = RGBAColor(hex: 0x111111)
    public static let white = RGBAColor(hex: 0xFFFFFF)

    public static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    public static func name(of color: RGBAColor) -> String {
        let names: [(RGBAColor, String)] = [
            (.red, "Red"), (.orange, "Orange"), (.yellow, "Yellow"), (.green, "Green"),
            (.blue, "Blue"), (.purple, "Purple"), (.black, "Black"), (.white, "White"),
        ]
        return names.first { $0.0.isSameHue(as: color) }?.1 ?? "Custom"
    }
}
