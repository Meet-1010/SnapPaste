import AppKit
import SnapPasteCore

/// An on-screen window the user can pick for a window capture.
struct WindowCandidate: Identifiable, Equatable {
    let id: CGWindowID
    /// Frame in Cocoa global coordinates.
    let frame: CGRect
    let appName: String
    let title: String

    var label: String {
        title.isEmpty || title == appName ? appName : "\(appName) — \(title)"
    }

    /// Visible windows from front to back, limited to ones ScreenCaptureKit can capture.
    static func onScreen(capturable: Set<CGWindowID>) -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowCandidate] = []
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, capturable.contains(id),
                  let layer = info[kCGWindowLayer as String] as? Int, (0...8).contains(layer),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 24
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            result.append(WindowCandidate(
                id: id,
                frame: ScreenGeometry.flipped(bounds, containerHeight: primaryHeight),
                appName: info[kCGWindowOwnerName as String] as? String ?? "Window",
                title: info[kCGWindowName as String] as? String ?? ""
            ))
        }
        return result
    }
}
