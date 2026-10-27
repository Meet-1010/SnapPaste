import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        NSApp.mainMenu = MainMenu.make(target: controller)
        controller.start()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SNAPPASTE_SAMPLE_EDITOR"] == "1" {
            controller.openSampleCaptureForTesting()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Drop the in-memory capture explicitly. The system clipboard is left untouched.
        controller?.shutdown()
        controller = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again (Finder, Spotlight) opens the menu instead of doing nothing.
        controller?.showMenu()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
