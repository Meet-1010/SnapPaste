import Foundation
import SnapPasteCore

enum ClearCaptureAfter: Int, CaseIterable, Identifiable {
    case never = 0
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case oneHour = 60

    var id: Int { rawValue }
    var minutes: Int? { self == .never ? nil : rawValue }

    var title: String {
        switch self {
        case .never: "Never (until quit)"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        case .oneHour: "After 1 hour"
        }
    }
}

/// User preferences. Only settings live in UserDefaults; screenshot pixels and recognized text never do.
@Observable
final class SettingsStore {
    private enum Key {
        static let quickCopy = "quickCopy"
        static let openEditorAfterCapture = "openEditorAfterCapture"
        static let showCopyConfirmation = "showCopyConfirmation"
        static let annotationColor = "annotationColor"
        static let lineWidth = "lineWidth"
        static let highlighterOpacity = "highlighterOpacity"
        static let textSize = "textSize"
        static let ocrLanguage = "ocrLanguage"
        static let ocrIncludesAnnotations = "ocrIncludesAnnotations"
        static let clearCaptureAfter = "clearCaptureAfterMinutes"
        static let shortcuts = "shortcuts"
    }

    enum Defaults {
        static let quickCopy = true
        static let openEditorAfterCapture = false
        static let showCopyConfirmation = true
        static let annotationColor = RGBAColor.red
        static let lineWidth = 6.0
        static let highlighterOpacity = 0.35
        static let textSize = 36.0
        static let ocrLanguage = "en-US"
        static let ocrIncludesAnnotations = false
        static let clearCaptureAfter = ClearCaptureAfter.fifteenMinutes
    }

    static let automaticLanguage = "automatic"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onShortcutsChanged: ((ShortcutConfiguration) -> Void)?

    var quickCopy: Bool { didSet { defaults.set(quickCopy, forKey: Key.quickCopy) } }
    var openEditorAfterCapture: Bool { didSet { defaults.set(openEditorAfterCapture, forKey: Key.openEditorAfterCapture) } }
    var showCopyConfirmation: Bool { didSet { defaults.set(showCopyConfirmation, forKey: Key.showCopyConfirmation) } }
    var annotationColor: RGBAColor { didSet { store(annotationColor, forKey: Key.annotationColor) } }
    var lineWidth: Double { didSet { defaults.set(lineWidth, forKey: Key.lineWidth) } }
    var highlighterOpacity: Double { didSet { defaults.set(highlighterOpacity, forKey: Key.highlighterOpacity) } }
    var textSize: Double { didSet { defaults.set(textSize, forKey: Key.textSize) } }
    var ocrLanguage: String { didSet { defaults.set(ocrLanguage, forKey: Key.ocrLanguage) } }
    var ocrIncludesAnnotations: Bool { didSet { defaults.set(ocrIncludesAnnotations, forKey: Key.ocrIncludesAnnotations) } }
    var clearCaptureAfter: ClearCaptureAfter { didSet { defaults.set(clearCaptureAfter.rawValue, forKey: Key.clearCaptureAfter) } }
    var shortcuts: ShortcutConfiguration {
        didSet {
            store(shortcuts, forKey: Key.shortcuts)
            onShortcutsChanged?(shortcuts)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quickCopy = defaults.object(forKey: Key.quickCopy) as? Bool ?? Defaults.quickCopy
        openEditorAfterCapture = defaults.object(forKey: Key.openEditorAfterCapture) as? Bool ?? Defaults.openEditorAfterCapture
        showCopyConfirmation = defaults.object(forKey: Key.showCopyConfirmation) as? Bool ?? Defaults.showCopyConfirmation
        annotationColor = Self.load(RGBAColor.self, key: Key.annotationColor, from: defaults) ?? Defaults.annotationColor
        lineWidth = defaults.object(forKey: Key.lineWidth) as? Double ?? Defaults.lineWidth
        highlighterOpacity = defaults.object(forKey: Key.highlighterOpacity) as? Double ?? Defaults.highlighterOpacity
        textSize = defaults.object(forKey: Key.textSize) as? Double ?? Defaults.textSize
        ocrLanguage = defaults.string(forKey: Key.ocrLanguage) ?? Defaults.ocrLanguage
        ocrIncludesAnnotations = defaults.object(forKey: Key.ocrIncludesAnnotations) as? Bool ?? Defaults.ocrIncludesAnnotations
        clearCaptureAfter = (defaults.object(forKey: Key.clearCaptureAfter) as? Int).flatMap(ClearCaptureAfter.init(rawValue:)) ?? Defaults.clearCaptureAfter
        shortcuts = Self.load(ShortcutConfiguration.self, key: Key.shortcuts, from: defaults) ?? .defaults
    }

    /// Languages passed to Vision; empty means automatic detection.
    var ocrLanguages: [String] {
        ocrLanguage == Self.automaticLanguage ? [] : [ocrLanguage]
    }

    /// Restores every preference except Launch at Login, which macOS owns.
    func restoreDefaults() {
        quickCopy = Defaults.quickCopy
        openEditorAfterCapture = Defaults.openEditorAfterCapture
        showCopyConfirmation = Defaults.showCopyConfirmation
        annotationColor = Defaults.annotationColor
        lineWidth = Defaults.lineWidth
        highlighterOpacity = Defaults.highlighterOpacity
        textSize = Defaults.textSize
        ocrLanguage = Defaults.ocrLanguage
        ocrIncludesAnnotations = Defaults.ocrIncludesAnnotations
        clearCaptureAfter = Defaults.clearCaptureAfter
        shortcuts = .defaults
    }

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
