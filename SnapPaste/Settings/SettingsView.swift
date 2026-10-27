import ServiceManagement
import SnapPasteCore
import SwiftUI

struct SettingsView: View {
    let controller: AppController
    let recorder: ShortcutRecorderModel

    var body: some View {
        TabView {
            GeneralSettingsView(controller: controller, settings: controller.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettingsView(settings: controller.settings, hotkeys: controller.hotkeys, recorder: recorder)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            EditorSettingsView(settings: controller.settings)
                .tabItem { Label("Editor", systemImage: "pencil.tip.crop.circle") }
            TextRecognitionSettingsView(settings: controller.settings)
                .tabItem { Label("Text", systemImage: "text.viewfinder") }
            PrivacySettingsView(controller: controller)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    let controller: AppController
    @Bindable var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var confirmRestore = false

    var body: some View {
        Form {
            Section {
                Toggle("Quick Copy", isOn: $settings.quickCopy)
                Text("Put every capture on the clipboard right away, ready to paste with ⌘V.")
                    .settingsCaption()
                Toggle("Open the editor after capturing", isOn: Binding(
                    get: { !settings.quickCopy || settings.openEditorAfterCapture },
                    set: { settings.openEditorAfterCapture = $0 }
                ))
                .disabled(!settings.quickCopy)
                Text(settings.quickCopy
                     ? "Edit first if you like, then click Copy to replace the clipboard with the edited image."
                     : "With Quick Copy off, captures always open in the editor and reach the clipboard when you click Copy.")
                    .settingsCaption()
                Toggle("Show a confirmation when something is copied", isOn: $settings.showCopyConfirmation)
            } header: {
                Text("After Capture")
            }

            Section("Memory") {
                Picker("Forget the last capture", selection: $settings.clearCaptureAfter) {
                    ForEach(ClearCaptureAfter.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.clearCaptureAfter) { controller.settingsDidChangeAutoClear() }
                Text("The last capture is kept in memory so you can edit or copy it again. It is never written to disk, and quitting SnapPaste always discards it.")
                    .settingsCaption()
            }

            Section("Startup") {
                Toggle("Launch SnapPaste at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve SnapPaste in System Settings › General › Login Items.").settingsCaption()
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults…") { confirmRestore = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore all SnapPaste settings to their defaults?", isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { settings.restoreDefaults() }
        } message: {
            Text("This resets capture behavior, shortcuts, editor defaults and text recognition. Launch at Login is not changed.")
        }
        .onAppear { refreshLoginStatus() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        let enabled = loginStatus == .enabled || loginStatus == .requiresApproval
        if launchAtLogin != enabled { launchAtLogin = enabled }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettingsView: View {
    let settings: SettingsStore
    let hotkeys: HotkeyManager
    let recorder: ShortcutRecorderModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(action.title) {
                            ShortcutField(action: action, settings: settings, recorder: recorder)
                        }
                        if let message = recorder.issues[action] ?? hotkeys.failures[action]?.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } footer: {
                Text("Click a shortcut and press new keys. Esc cancels, Delete removes. Global shortcuts need ⌘ or ⌃, and SnapPaste won't accept combinations macOS already uses.")
                    .settingsCaption()
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Default Shortcuts") { recorder.restoreDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }
}

// MARK: - Editor

private struct EditorSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Color") {
                    ColorSwatchRow(selection: settings.annotationColor) { settings.annotationColor = $0 }
                }
                LabeledContent("Line thickness") {
                    SliderWithValue(value: $settings.lineWidth, range: 1...40, unit: "px")
                }
                LabeledContent("Highlighter opacity") {
                    SliderWithValue(value: $settings.highlighterOpacity, range: 0.15...0.8, unit: "%", displayScale: 100)
                }
                LabeledContent("Text size") {
                    SliderWithValue(value: $settings.textSize, range: 10...160, unit: "px")
                }
            } header: {
                Text("Default Annotation Style")
            } footer: {
                Text("Sizes are in image pixels. On a Retina display, one point on screen is two pixels in the capture.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Text recognition

private struct TextRecognitionSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var languages: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.ocrLanguage) {
                    Text("Automatic").tag(SettingsStore.automaticLanguage)
                    Divider()
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Toggle("Include annotations when extracting text from a capture", isOn: $settings.ocrIncludesAnnotations)
                Text("Off: text is read from the screenshot itself. On: text you typed onto the capture is included too.")
                    .settingsCaption()
            } footer: {
                Text("Recognition runs entirely on this Mac with Apple's Vision framework. Recognized text is shown in the Extract Text window only and is not saved.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if languages.isEmpty {
                var supported = TextRecognizer.supportedLanguages()
                if !supported.contains(settings.ocrLanguage), settings.ocrLanguage != SettingsStore.automaticLanguage {
                    supported.append(settings.ocrLanguage)
                }
                languages = supported
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacySettingsView: View {
    let controller: AppController

    var body: some View {
        Form {
            Section("How SnapPaste handles your screenshots") {
                PrivacyRow(symbol: "memorychip", text: "Captures live in memory only. They are never written to disk, and there is no history or gallery.")
                PrivacyRow(symbol: "doc.on.clipboard", text: "Copying places a PNG on the system clipboard. Quitting SnapPaste doesn't clear or change your clipboard.")
                PrivacyRow(symbol: "network.slash", text: "No network access, accounts, analytics or uploads. The app is sandboxed without network permission.")
                PrivacyRow(symbol: "text.viewfinder", text: "Text recognition runs on this Mac with Apple's Vision framework.")
                PrivacyRow(symbol: "keyboard", text: "Shortcuts use macOS hot keys: SnapPaste is told only when one of its own shortcuts is pressed and never sees other typing.")
            }
            Section("Right Now") {
                LabeledContent("Capture in memory") {
                    HStack {
                        if let document = controller.captureStore.document {
                            Text("\(document.pixelSize.description) px").foregroundStyle(.secondary)
                            Button("Forget Now") { controller.clearCapture() }
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Screen Recording") {
                    HStack {
                        Text(controller.permission.isGranted ? "Allowed" : "Not allowed").foregroundStyle(.secondary)
                        Button(controller.permission.isGranted ? "Open System Settings" : "Fix…") {
                            if controller.permission.isGranted {
                                controller.permission.openSystemSettings()
                            } else {
                                controller.showPermissionHelp()
                            }
                        }
                    }
                }
                LabeledContent("Accessibility") {
                    Text("Not needed").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.permission.refresh() }
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared controls

struct SliderWithValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var displayScale: Double = 1
    var onEditingEnded: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range) { editing in
                if !editing { onEditingEnded?() }
            }
            .frame(width: 150)
            Text("\(Int((value * displayScale).rounded())) \(unit)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

extension Text {
    func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
