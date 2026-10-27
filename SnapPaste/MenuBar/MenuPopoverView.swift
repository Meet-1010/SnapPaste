import SnapPasteCore
import SwiftUI

/// Compact popover shown from the menu-bar icon. Navigable with ↑/↓, Return and Escape.
struct MenuPopoverView: View {
    let controller: AppController
    let state: MenuPopoverState
    let dismiss: () -> Void

    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var shortcut: String?
        var enabled = true
        let run: () -> Void
    }

    private var captureEntries: [Entry] {
        [
            Entry(id: "region", title: "Capture Region", symbol: "rectangle.dashed",
                  shortcut: controller.shortcutLabel(for: .captureRegion)) { controller.startCapture(.region) },
            Entry(id: "window", title: "Capture Window", symbol: "macwindow",
                  shortcut: controller.shortcutLabel(for: .captureWindow)) { controller.startCapture(.window) },
            Entry(id: "screen", title: "Capture Entire Screen", symbol: "display",
                  shortcut: controller.shortcutLabel(for: .captureScreen)) { controller.startCapture(.screen(nil)) },
            Entry(id: "ocr-region", title: "Extract Text…", symbol: "text.viewfinder",
                  shortcut: controller.shortcutLabel(for: .extractText)) { controller.extractTextFromRegion() },
        ]
    }

    private var lastCaptureEntries: [Entry] {
        let hasCapture = controller.captureStore.hasCapture
        return [
            Entry(id: "edit", title: "Edit Last Capture", symbol: "pencil.and.outline",
                  shortcut: controller.shortcutLabel(for: .openEditor), enabled: hasCapture) { controller.openEditorForLastCapture() },
            Entry(id: "copy", title: "Copy Last Capture", symbol: "doc.on.doc",
                  shortcut: controller.shortcutLabel(for: .copyLastCapture), enabled: hasCapture) { controller.copyLastCapture() },
            Entry(id: "ocr-last", title: "Extract Text from Last Capture", symbol: "doc.text.viewfinder",
                  enabled: hasCapture) { controller.extractTextFromLastCapture() },
        ]
    }

    private var footerEntries: [Entry] {
        [
            Entry(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { controller.showSettings(nil) },
            Entry(id: "quit", title: "Quit SnapPaste", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) },
        ]
    }

    private var navigable: [Entry] {
        (captureEntries + lastCaptureEntries + footerEntries).filter(\.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !controller.permission.isGranted {
                notice(symbol: "lock.shield", text: "Screen Recording permission is needed to capture.", button: "Fix…") {
                    dismiss()
                    controller.showPermissionHelp()
                }
            }
            if !controller.hotkeys.failures.isEmpty {
                notice(symbol: "keyboard.badge.exclamationmark", text: "Some shortcuts couldn't be registered.", button: "Settings…") {
                    dismiss()
                    controller.showSettings(nil)
                }
            }
            section(captureEntries)
            Divider().padding(.vertical, 4)
            if let thumbnail = controller.lastCaptureThumbnail, let document = controller.captureStore.document {
                lastCaptureCard(thumbnail: thumbnail, document: document)
            }
            section(lastCaptureEntries)
            Divider().padding(.vertical, 4)
            section(footerEntries)
        }
        .padding(6)
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.return) { activateHighlighted(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onAppear {
            state.highlighted = nil
            focused = true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("SnapPaste").font(.headline)
            Spacer()
            Text("Clipboard only · nothing saved")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func section(_ entries: [Entry]) -> some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                MenuRow(entry: entry, isHighlighted: state.highlighted == entry.id && entry.enabled)
                    .onHover { inside in
                        if inside && entry.enabled { state.highlighted = entry.id }
                        else if !inside && state.highlighted == entry.id { state.highlighted = nil }
                    }
                    .onTapGesture {
                        guard entry.enabled else { return }
                        run(entry)
                    }
            }
        }
    }

    private func lastCaptureCard(thumbnail: NSImage, document: EditorDocument) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 72, maxHeight: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .accessibilityLabel("Last capture preview")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(document.pixelSize.description) px")
                    .font(.callout.monospacedDigit())
                if let date = controller.captureStore.capturedAt {
                    Text("Captured \(date, style: .relative) ago · in memory only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                controller.clearCapture()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Forget this capture (frees its memory)")
            .accessibilityLabel("Forget last capture")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func notice(symbol: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
    }

    private func moveHighlight(_ delta: Int) {
        let items = navigable
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == state.highlighted }
        let next: Int
        if let current {
            next = (current + delta + items.count) % items.count
        } else {
            next = delta > 0 ? 0 : items.count - 1
        }
        state.highlighted = items[next].id
    }

    private func activateHighlighted() {
        guard let entry = navigable.first(where: { $0.id == state.highlighted }) else { return }
        run(entry)
    }

    private func run(_ entry: Entry) {
        dismiss()
        entry.run()
    }
}

private struct MenuRow: View {
    let entry: MenuPopoverView.Entry
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
            Text(entry.title)
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .opacity(entry.enabled ? 1 : 0.4)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(isHighlighted ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityHint(entry.shortcut.map { "Shortcut \($0)" } ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// Popover state that outlives the SwiftUI view, so the controller can reset it on every open.
@Observable
final class MenuPopoverState {
    var highlighted: String?
}
