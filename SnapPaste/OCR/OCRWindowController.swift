import AppKit
import SnapPasteCore
import SwiftUI

/// Runs one recognition at a time and holds its text only while the window is open.
@Observable
final class OCRSession {
    enum Phase: Equatable {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    var phase: Phase = .cancelled
    var text = ""
    private(set) var source = ""
    private(set) var imageSize: PixelSize?
    private(set) var lineCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(_ image: CGImage, source: String, recognizer: TextRecognizer) {
        task?.cancel()
        phase = .running
        text = ""
        lineCount = 0
        self.source = source
        imageSize = PixelSize(image)
        task = Task { [weak self] in
            do {
                let result = try await recognizer.recognize(image)
                guard !Task.isCancelled, let self else { return }
                text = result.text
                lineCount = result.lines.count
                phase = .finished
            } catch is CancellationError {
                return
            } catch {
                self?.phase = .failed((error as? OCRError)?.message ?? error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = .cancelled }
    }

    /// Forgets the recognized text when the window closes.
    func clear() {
        cancel()
        text = ""
        lineCount = 0
        imageSize = nil
    }
}

final class OCRWindowController: NSWindowController, NSWindowDelegate {
    private let session = OCRSession()
    private let onClose: () -> Void

    init(onCopy: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Extract Text"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        let view = OCRView(session: session, copy: onCopy, close: { [weak window] in window?.close() })
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func recognize(_ image: CGImage, source: String, recognizer: TextRecognizer) {
        session.start(image, source: source, recognizer: recognizer)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        session.clear()
        DispatchQueue.main.async { [onClose] in onClose() }
    }
}

private struct OCRView: View {
    @Bindable var session: OCRSession
    let copy: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Extracted Text").font(.headline)
                Text([session.source, session.imageSize.map { "\($0.description) px" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .running:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Recognizing text…").foregroundStyle(.secondary)
                Button("Cancel") { session.cancel() }
            }
        case .cancelled:
            ContentUnavailableView("Recognition Cancelled", systemImage: "xmark.circle",
                                   description: Text("Capture again to extract text."))
        case .failed(let message):
            ContentUnavailableView("Couldn't Recognize Text", systemImage: "exclamationmark.triangle", description: Text(message))
        case .finished where session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            ContentUnavailableView("No Text Found", systemImage: "text.magnifyingglass",
                                   description: Text("SnapPaste couldn't find readable text in this image."))
        case .finished:
            TextEditor(text: $session.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityLabel("Recognized text")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if session.phase == .finished, !session.text.isEmpty {
                Text("\(session.lineCount) \(session.lineCount == 1 ? "line" : "lines") · \(session.text.count) characters · recognized on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Text is recognized on this Mac and isn't saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: close)
                .keyboardShortcut(.cancelAction)
            Button {
                copy(session.text)
            } label: {
                Label("Copy Extracted Text", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(session.phase != .finished || session.text.isEmpty)
            .help("Copy all of the text (⇧⌘C). Select part of the text and press ⌘C to copy just that.")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}
