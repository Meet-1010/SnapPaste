import SnapPasteCore
import SwiftUI

struct ResizeView: View {
    let original: PixelSize
    let apply: (PixelSize) throws -> Void
    let cancel: () -> Void

    @State private var width: Int
    @State private var height: Int
    @State private var keepsAspectRatio = true
    @State private var failure: String?
    @FocusState private var focusedField: Field?

    private enum Field { case width, height }

    init(original: PixelSize, apply: @escaping (PixelSize) throws -> Void, cancel: @escaping () -> Void) {
        self.original = original
        self.apply = apply
        self.cancel = cancel
        _width = State(initialValue: original.width)
        _height = State(initialValue: original.height)
    }

    private var target: PixelSize { PixelSize(width: width, height: height) }
    private var issue: ResizeMath.Issue? { ResizeMath.validate(target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resize Image").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: $width, format: .number.grouping(.never))
                        .frame(width: 80)
                        .focused($focusedField, equals: .width)
                        .onChange(of: width) { _, new in
                            if keepsAspectRatio, focusedField != .height {
                                height = ResizeMath.height(forWidth: new, preservingAspectOf: original)
                            }
                        }
                    Text("px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: $height, format: .number.grouping(.never))
                        .frame(width: 80)
                        .focused($focusedField, equals: .height)
                        .onChange(of: height) { _, new in
                            if keepsAspectRatio, focusedField == .height {
                                width = ResizeMath.width(forHeight: new, preservingAspectOf: original)
                            }
                        }
                    Text("px").foregroundStyle(.secondary)
                }
            }
            Toggle("Keep aspect ratio", isOn: $keepsAspectRatio)
                .onChange(of: keepsAspectRatio) { _, keeps in
                    if keeps { height = ResizeMath.height(forWidth: width, preservingAspectOf: original) }
                }
            HStack(spacing: 6) {
                ForEach([25, 50, 75, 200], id: \.self) { percent in
                    Button("\(percent)%") {
                        focusedField = nil
                        let scaled = ResizeMath.scaled(original, by: Double(percent) / 100)
                        width = scaled.width
                        height = scaled.height
                    }
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(original.description) → \(target.description) px")
                    .font(.callout.monospacedDigit())
                if let message = issue?.message ?? failure {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Resize") {
                    do {
                        try apply(target)
                    } catch let error as ResizeMath.Issue {
                        failure = error.message
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(issue != nil || target == original)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
