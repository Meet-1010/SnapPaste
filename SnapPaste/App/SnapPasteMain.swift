import AppKit

@main
enum SnapPasteMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar utility: no Dock icon (LSUIElement is also set in Info.plist).
        app.setActivationPolicy(.accessory)
        #if DEBUG
        // UI-automation tools only see regular apps.
        if ProcessInfo.processInfo.environment["SNAPPASTE_REGULAR_APP"] == "1" {
            app.setActivationPolicy(.regular)
        }
        #endif
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
