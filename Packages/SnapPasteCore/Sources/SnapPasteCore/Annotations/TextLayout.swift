import AppKit
import CoreText

/// Text metrics shared by the editor's live text field, hit testing, and final rendering.
public enum TextLayout {
    public static let fontWeight: NSFont.Weight = .semibold

    public static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: max(1, size), weight: fontWeight)
    }

    public static func attributedString(_ string: String, fontSize: CGFloat, color: CGColor?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(size: fontSize)]
        if let color {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color
        }
        // An empty string still needs a line box so the caret and bounds have height.
        return NSAttributedString(string: string.isEmpty ? " " : string, attributes: attributes)
    }

    /// Size of the laid-out text in the same units as `fontSize`.
    public static func size(of string: String, fontSize: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(string, fontSize: fontSize, color: nil))
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        return CGSize(width: ceil(suggested.width) + 2, height: ceil(suggested.height) + 2)
    }
}
