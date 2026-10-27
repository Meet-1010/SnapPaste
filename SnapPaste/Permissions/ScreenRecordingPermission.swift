import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission, which ScreenCaptureKit needs for still captures.
@Observable
final class ScreenRecordingPermission {
    enum Check {
        case granted
        /// The system prompt was just shown; the user decides there.
        case promptShown
        case denied
    }

    private(set) var isGranted = CGPreflightScreenCaptureAccess()
    @ObservationIgnored private let defaults: UserDefaults
    private static let promptedKey = "hasRequestedScreenRecording"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refresh() {
        isGranted = CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt only the first time. macOS won't prompt again after the user has
    /// answered, so later attempts go to SnapPaste's own help window instead of failing silently,
    /// and a denied permission never turns into a prompt loop.
    func checkBeforeCapture() -> Check {
        refresh()
        if isGranted { return .granted }
        guard !defaults.bool(forKey: Self.promptedKey) else { return .denied }
        defaults.set(true, forKey: Self.promptedKey)
        return requestAccess() ? .granted : .promptShown
    }

    /// Explicit request from the help window.
    @discardableResult
    func requestAccess() -> Bool {
        isGranted = CGRequestScreenCaptureAccess()
        return isGranted
    }

    func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// macOS applies a newly granted Screen Recording permission to new processes, so offer a relaunch.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
