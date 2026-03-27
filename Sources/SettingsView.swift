import SwiftUI
import AppKit

enum SettingsKeys {
    static let runnerPath = "dslRunnerPath"
    static let runnerBookmark = "dslRunnerBookmark"
    static let runnerDirectoryBookmark = "dslRunnerDirectoryBookmark"
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let showLineNumbers = "showLineNumbers"
    static let editorIndentationStyle = "editorIndentationStyle"
    static let editorAutosaveInterval = "editorAutosaveInterval"
    static let restoreOpenTabsOnLaunch = "restoreOpenTabsOnLaunch"
    static let editorBaseColor = "editorBaseColor"
    static let editorKeywordColor = "editorKeywordColor"
    static let editorNumberColor = "editorNumberColor"
    static let editorVariableColor = "editorVariableColor"
    static let editorCommentColor = "editorCommentColor"
    static let editorErrorUnderlineColor = "editorErrorUnderlineColor"
    static let editorErrorCheckingEnabled = "editorErrorCheckingEnabled"
}

enum EditorIndentationStyle: String, CaseIterable, Identifiable {
    case twoSpaces
    case fourSpaces
    case tab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoSpaces:
            "2 Spaces"
        case .fourSpaces:
            "4 Spaces"
        case .tab:
            "Tab"
        }
    }

    var indentUnit: String {
        switch self {
        case .twoSpaces:
            "  "
        case .fourSpaces:
            "    "
        case .tab:
            "\t"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.runnerPath) private var runnerPath: String = ""
    @AppStorage(SettingsKeys.editorFontName) private var editorFontName: String = "Menlo"
    @AppStorage(SettingsKeys.editorFontSize) private var editorFontSize: Double = 13
    @AppStorage(SettingsKeys.showLineNumbers) private var showLineNumbers = true
    @AppStorage(SettingsKeys.editorIndentationStyle) private var editorIndentationStyleRawValue = EditorIndentationStyle.fourSpaces.rawValue
    @AppStorage(SettingsKeys.editorAutosaveInterval) private var editorAutosaveInterval: Double = 0
    @AppStorage(SettingsKeys.restoreOpenTabsOnLaunch) private var restoreOpenTabsOnLaunch = true
    @AppStorage(SettingsKeys.editorErrorCheckingEnabled) private var editorErrorCheckingEnabled = true
    @AppStorage(SettingsKeys.editorBaseColor) private var editorBaseColorHex: String = ""
    @AppStorage(SettingsKeys.editorKeywordColor) private var editorKeywordColorHex: String = ""
    @AppStorage(SettingsKeys.editorNumberColor) private var editorNumberColorHex: String = ""
    @AppStorage(SettingsKeys.editorVariableColor) private var editorVariableColorHex: String = ""
    @AppStorage(SettingsKeys.editorCommentColor) private var editorCommentColorHex: String = ""
    @AppStorage(SettingsKeys.editorErrorUnderlineColor) private var editorErrorUnderlineColorHex: String = ""

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }

                appearanceTab
                    .tabItem {
                        Label("Appearance", systemImage: "paintpalette")
                    }
            }
            .padding(16)

            Divider()

            HStack {
                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runner Program")
                .font(.headline)

            HStack {
                TextField("/path/to/program", text: $runnerPath)
                    .textFieldStyle(.roundedBorder)

                Button("Choose...") {
                    chooseRunner()
                }
                .disabled(!isRunnerPickerAvailable)
            }

            Text("The program will be executed as: <program> --script <file>")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("Autosave")
                .font(.headline)

            Toggle("Enable Autosave", isOn: autosaveEnabledBinding)

            if editorAutosaveInterval > 0 {
                Stepper(value: $editorAutosaveInterval, in: 5 ... 300, step: 5) {
                    Text("Save every \(Int(editorAutosaveInterval)) seconds")
                }

                Text("Autosave only writes to an already saved file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("Restore Open Tabs On Launch", isOn: $restoreOpenTabsOnLaunch)

            Text("When enabled, the editor restores file-backed tabs and windows on restart.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Enable Error Checking", isOn: $editorErrorCheckingEnabled)

            Text("When disabled, syntax validation and editor error diagnostics are skipped.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Editor Font")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Font", selection: $editorFontName) {
                    ForEach(availableEditorFonts, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }
                .frame(maxWidth: 260)

                Stepper(value: $editorFontSize, in: 9 ... 36, step: 1) {
                    Text("Size \(Int(editorFontSize))")
                }
                .frame(width: 140)
            }

            Text("Choose the font family and point size used in the editor.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Show Line Numbers", isOn: $showLineNumbers)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Indentation", selection: editorIndentationStyleBinding) {
                    ForEach(EditorIndentationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .frame(maxWidth: 220)

                Text("Used for automatic block indentation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Reset Appearance Defaults") {
                    resetAppearanceDefaults()
                }

                Spacer()
            }

            Divider()

            Text("Editor Colors")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.fixed(160), alignment: .leading),
                GridItem(.flexible(minimum: 180), alignment: .leading)
            ], alignment: .leading, spacing: 10) {
                Text("Base Text")
                ColorPicker("", selection: baseColorBinding, supportsOpacity: false)
                    .labelsHidden()

                Text("Keywords")
                ColorPicker("", selection: keywordColorBinding, supportsOpacity: false)
                    .labelsHidden()

                Text("Numbers")
                ColorPicker("", selection: numberColorBinding, supportsOpacity: false)
                    .labelsHidden()

                Text("Variables")
                ColorPicker("", selection: variableColorBinding, supportsOpacity: false)
                    .labelsHidden()

                Text("Comments")
                ColorPicker("", selection: commentColorBinding, supportsOpacity: false)
                    .labelsHidden()

                Text("Error Underline")
                ColorPicker("", selection: errorUnderlineColorBinding, supportsOpacity: false)
                    .labelsHidden()
            }

            Text("These colors are applied live to the editor syntax highlighting.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private func chooseRunner() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Runner Program"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            runnerPath = url.path
            SecurityScopedAccess.storeBookmark(for: url, defaultsKey: SettingsKeys.runnerBookmark)
            SecurityScopedAccess.storeBookmark(for: url.deletingLastPathComponent(), defaultsKey: SettingsKeys.runnerDirectoryBookmark)
        }
    }

    private var isRunnerPickerAvailable: Bool {
        true
    }

    private var availableEditorFonts: [String] {
        let preferredFonts = [
            "Menlo",
            "Monaco",
            "SF Mono",
            "Courier",
            "Courier New",
            "Andale Mono"
        ]
        let installedFonts = Set(NSFontManager.shared.availableFontFamilies)
        let availablePreferredFonts = preferredFonts.filter { installedFonts.contains($0) }
        return availablePreferredFonts.isEmpty ? ["Menlo"] : availablePreferredFonts
    }

    private var baseColorBinding: Binding<Color> {
        colorBinding(hex: $editorBaseColorHex, fallback: .textColor)
    }

    private var keywordColorBinding: Binding<Color> {
        colorBinding(hex: $editorKeywordColorHex, fallback: .systemBlue)
    }

    private var numberColorBinding: Binding<Color> {
        colorBinding(hex: $editorNumberColorHex, fallback: .systemOrange)
    }

    private var variableColorBinding: Binding<Color> {
        colorBinding(hex: $editorVariableColorHex, fallback: .systemPurple)
    }

    private var commentColorBinding: Binding<Color> {
        colorBinding(hex: $editorCommentColorHex, fallback: .systemGreen)
    }

    private var errorUnderlineColorBinding: Binding<Color> {
        colorBinding(hex: $editorErrorUnderlineColorHex, fallback: .systemRed)
    }

    private func colorBinding(hex: Binding<String>, fallback: NSColor) -> Binding<Color> {
        Binding<Color>(
            get: {
                let color = NSColor(hexString: hex.wrappedValue) ?? fallback
                return Color(nsColor: color)
            },
            set: { newColor in
                hex.wrappedValue = NSColor(newColor).hexStringValue ?? ""
            }
        )
    }

    private var autosaveEnabledBinding: Binding<Bool> {
        Binding<Bool>(
            get: {
                editorAutosaveInterval > 0
            },
            set: { isEnabled in
                editorAutosaveInterval = isEnabled ? max(editorAutosaveInterval, 30) : 0
            }
        )
    }

    private var editorIndentationStyleBinding: Binding<EditorIndentationStyle> {
        Binding(
            get: {
                EditorIndentationStyle(rawValue: editorIndentationStyleRawValue) ?? .fourSpaces
            },
            set: { newValue in
                editorIndentationStyleRawValue = newValue.rawValue
            }
        )
    }

    private func resetAppearanceDefaults() {
        editorFontName = "Menlo"
        editorFontSize = 13
        showLineNumbers = true
        editorIndentationStyleRawValue = EditorIndentationStyle.fourSpaces.rawValue
        editorBaseColorHex = ""
        editorKeywordColorHex = ""
        editorNumberColorHex = ""
        editorVariableColorHex = ""
        editorCommentColorHex = ""
        editorErrorUnderlineColorHex = ""
    }
}
