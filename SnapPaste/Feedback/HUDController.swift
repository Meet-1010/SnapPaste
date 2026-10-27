import AppKit
import SwiftUI

/// A small, click-through confirmation bubble near the top of the active screen.
/// It never takes focus, and it is torn down as soon as it fades out.
final class HUDController {
    enum Style {
        case normal
        case warning
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ title: String, detail: String? = nil, symbol: String, style: Style = .normal) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: HUDView(title: title, detail: detail, symbol: symbol, style: style))
        let size = hosting.fittingSize
        let screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16, width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel

        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: [title, detail].compactMap { $0 }.joined(separator: ", "),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])

        let duration: Duration = style == .warning ? .seconds(3.5) : .seconds(1.4)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                if self?.panel === panel { self?.panel = nil }
            }
        })
    }
}

private struct HUDView: View {
    let title: String
    let detail: String?
    let symbol: String
    let style: HUDController.Style

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(style == .warning ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .padding(1)
    }
}
