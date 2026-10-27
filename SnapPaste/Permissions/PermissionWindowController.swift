import AppKit
import SwiftUI

final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(permission: ScreenRecordingPermission, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Screen Recording Permission"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(rootView: PermissionView(permission: permission, close: { [weak self] in self?.close() }))
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [onClose] in onClose() }
    }
}

private struct PermissionView: View {
    let permission: ScreenRecordingPermission
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: permission.isGranted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(permission.isGranted ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(permission.isGranted ? "Screen Recording is allowed" : "Allow Screen Recording")
                        .font(.title3.weight(.semibold))
                    Text("macOS only lets apps read the contents of your screen with Screen Recording permission. SnapPaste uses it solely to take the still image you ask for; nothing is recorded continuously, saved, or uploaded.")
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
            }
            if !permission.isGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click Open System Settings.")
                    Text("2. Turn on SnapPaste under Screen & System Audio Recording.")
                    Text("3. Click Quit & Reopen so the change takes effect.")
                }
                .font(.callout)
            } else {
                Text("If captures still fail, reopen SnapPaste so macOS applies the permission.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Check Again") { permission.refresh() }
                if !permission.isGranted {
                    Button("Request Access") { permission.requestAccess() }
                        .help("Ask macOS to show its Screen Recording prompt or list SnapPaste in System Settings")
                }
                Spacer()
                Button("Quit & Reopen") { permission.relaunch() }
                if permission.isGranted {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") { permission.openSystemSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
        }
    }
}
