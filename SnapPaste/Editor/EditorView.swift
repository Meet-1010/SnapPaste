import SnapPasteCore
import SwiftUI

struct EditorView: View {
    @Bindable var session: EditorSession
    let commands: EditorCommandProxy

    @State private var showResize = false
    @State private var confirmReset = false

    private var document: EditorDocument { session.document }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            optionsBar
            Divider()
            CanvasHost(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .confirmationDialog("Reset all edits?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                session.canvas?.commitTextEditing()
                session.selectedID = nil
                session.cropRect = nil
                document.resetToOriginal()
            }
        } message: {
            Text("Removes all annotations and undoes crop and resize. You can undo this with ⌘Z.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                IconButton(symbol: tool.symbolName, label: tool.title, help: "\(tool.title) (\(String(tool.key).uppercased()))",
                           isSelected: session.tool == tool) {
                    session.tool = tool
                }
            }
            separator
            IconButton(symbol: "arrow.uturn.backward", label: "Undo",
                       help: document.undoActionName.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)") {
                session.canvas?.snapUndo(nil)
            }
            .disabled(!document.canUndo)
            IconButton(symbol: "arrow.uturn.forward", label: "Redo",
                       help: document.redoActionName.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)") {
                session.canvas?.snapRedo(nil)
            }
            .disabled(!document.canRedo)
            separator
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Resize", help: "Resize Image…") {
                session.canvas?.commitTextEditing()
                showResize = true
            }
            .popover(isPresented: $showResize, arrowEdge: .bottom) {
                ResizeView(original: document.pixelSize) { size in
                    try document.resize(to: size)
                    showResize = false
                } cancel: {
                    showResize = false
                }
            }
            IconButton(symbol: "text.viewfinder", label: "Extract Text", help: "Extract Text") {
                commands.extractText()
            }
            IconButton(symbol: "arrow.counterclockwise", label: "Reset Edits", help: "Reset Edits…") {
                confirmReset = true
            }
            .disabled(!document.hasEdits)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 20).padding(.horizontal, 6)
    }

    // MARK: Contextual options

    private var optionsBar: some View {
        HStack(spacing: 16) {
            switch session.tool {
            case .crop:
                cropOptions
            case .eraser:
                hint("Click or drag across annotations to remove them. The screenshot itself is never erased.")
            case .select where session.selectedID == nil:
                hint("Click an annotation to select it · drag to move · ⌫ deletes · double-click text to edit")
            default:
                styleControls
            }
            if session.tool != .crop {
                Spacer(minLength: 0)
            }
            if session.selectedID != nil, session.tool == .select || session.tool == .text, !session.isEditingText {
                Button(role: .destructive) {
                    session.canvas?.deleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Delete selected annotation (⌫)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    @ViewBuilder
    private var styleControls: some View {
        ColorSwatchRow(selection: session.activeColor) { session.setColor($0) }
        if session.editsText {
            LabeledSlider(title: "Size", value: Binding(get: { session.fontSize }, set: { session.setFontSize($0) }),
                          range: 10...200, unit: "px", onEditingEnded: session.finishStyleChange)
            hint(session.isEditingText ? "↩ done · ⌥↩ new line · esc cancel" : "Click to add text · drag text to move it")
        } else {
            LabeledSlider(title: "Thickness", value: Binding(get: { session.activeWidth }, set: { session.setWidth($0) }),
                          range: session.editsHighlighter ? 6...80 : 1...40, unit: "px", onEditingEnded: session.finishStyleChange)
            if session.editsHighlighter {
                LabeledSlider(title: "Opacity", value: Binding(get: { session.highlighterOpacity }, set: { session.setOpacity($0) }),
                              range: 0.15...0.8, unit: "%", displayScale: 100, onEditingEnded: session.finishStyleChange)
            } else if session.tool != .select {
                hint("Hold ⇧ to constrain")
            }
        }
    }

    @ViewBuilder
    private var cropOptions: some View {
        Image(systemName: "crop").foregroundStyle(.secondary)
        if let crop = session.cropRect {
            Text("\(Int(crop.width)) × \(Int(crop.height)) px")
                .font(.callout.monospacedDigit())
        } else {
            hint("Drag on the image to choose the area to keep")
        }
        Spacer(minLength: 0)
        Button("Cancel") { session.canvas?.cancelCrop() }
            .disabled(session.cropRect == nil)
            .help("Clear the crop selection (esc)")
        Button("Apply Crop") { session.canvas?.applyCrop() }
            .buttonStyle(.borderedProminent)
            .disabled(session.cropRect.map { !CropMath.changesImage($0, within: document.pixelSize) } ?? true)
            .help("Crop to the selection (↩)")
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text("\(document.pixelSize.description) px")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Size of the image that will be copied")
            separator
            IconButton(symbol: "minus.magnifyingglass", label: "Zoom Out", help: "Zoom Out (⌘−)") { session.canvas?.zoomOut(nil) }
            Text("\(session.zoomPercent)%")
                .font(.callout.monospacedDigit())
                .frame(width: 46)
                .accessibilityLabel("Zoom \(session.zoomPercent) percent")
            IconButton(symbol: "plus.magnifyingglass", label: "Zoom In", help: "Zoom In (⌘=)") { session.canvas?.zoomIn(nil) }
            Button("Fit") { session.canvas?.zoomToFit(nil) }
                .controlSize(.small)
                .help("Zoom to Fit (⌘0)")
            Button("100%") { session.canvas?.zoomToActualSize(nil) }
                .controlSize(.small)
                .help("Actual Size: one image pixel per screen pixel (⌘1)")
            Spacer()
            Button("Cancel") { commands.cancel() }
                .help("Close without changing the clipboard (esc)")
            Button {
                commands.copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the edited image to the clipboard (⌘C)")
            Button {
                commands.copyAndClose()
            } label: {
                Label("Copy & Close", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .help("Copy the edited image and close the editor (⌘↩)")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }
}

// MARK: - Components

private struct CanvasHost: NSViewRepresentable {
    let session: EditorSession

    func makeNSView(context: Context) -> EditorCanvasView {
        EditorCanvasView(session: session)
    }

    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}

struct IconButton: View {
    let symbol: String
    let label: String
    let help: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ColorSwatchRow: View {
    let selection: RGBAColor
    let onSelect: (RGBAColor) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RGBAColor.palette, id: \.self) { color in
                let selected = color.isSameHue(as: selection)
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(Color(cgColor: color.cgColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(RGBAColor.name(of: color))
                .accessibilityLabel(RGBAColor.name(of: color))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var displayScale: Double = 1
    var onEditingEnded: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 }), in: range) { editing in
                if !editing { onEditingEnded() }
            }
            .controlSize(.small)
            .frame(width: 110)
            .accessibilityLabel(title)
            Text("\(Int((value * displayScale).rounded())) \(unit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        }
    }
}
