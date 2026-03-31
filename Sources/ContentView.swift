import SwiftUI

struct ContentView: View {
    @Binding private var filePath: String
    @StateObject private var model: EditorModel
    @State private var windowID = UUID().uuidString
    @AppStorage(SettingsKeys.editorFontName) private var editorFontName: String = "Menlo"
    @AppStorage(SettingsKeys.editorFontSize) private var editorFontSize: Double = 13
    @AppStorage(SettingsKeys.showLineNumbers) private var showLineNumbers = true
    @AppStorage(SettingsKeys.editorIndentationStyle) private var editorIndentationStyleRawValue = EditorIndentationStyle.fourSpaces.rawValue
    @AppStorage(SettingsKeys.restoreOpenTabsOnLaunch) private var restoreOpenTabsOnLaunch = true
    @AppStorage(SettingsKeys.editorErrorCheckingEnabled) private var editorErrorCheckingEnabled = true
    @AppStorage(SettingsKeys.editorBaseColor) private var editorBaseColorHex: String = ""
    @AppStorage(SettingsKeys.editorKeywordColor) private var editorKeywordColorHex: String = ""
    @AppStorage(SettingsKeys.editorNumberColor) private var editorNumberColorHex: String = ""
    @AppStorage(SettingsKeys.editorVariableColor) private var editorVariableColorHex: String = ""
    @AppStorage(SettingsKeys.editorCommentColor) private var editorCommentColorHex: String = ""
    @AppStorage(SettingsKeys.editorErrorUnderlineColor) private var editorErrorUnderlineColorHex: String = ""

    init(filePath: Binding<String>) {
        _filePath = filePath
        _model = StateObject(
            wrappedValue: EditorModel(
                initialFilePath: filePath.wrappedValue.isEmpty ? nil : filePath.wrappedValue
            )
        )
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.loadFile()
                } label: {
                    toolbarButtonLabel("Open", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    model.saveFile()
                } label: {
                    toolbarButtonLabel("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    model.correctIndentation(using: resolvedIndentationStyle.indentUnit)
                } label: {
                    toolbarButtonLabel("Indent", systemImage: "text.insert")
                }
                .buttonStyle(.bordered)

                Button {
                    model.runScript()
                } label: {
                    toolbarButtonLabel("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)

                Spacer()

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)

            Divider()

            editorSection

            Divider()

            diagnosticsSection

            Divider()

            statusBarSection
        }
        .frame(minWidth: 900, minHeight: 640)
        .navigationTitle(model.documentTitle)
        .focusedSceneObject(model)
        .onReceive(model.$currentFileURL) { currentFileURL in
            filePath = currentFileURL?.path ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: ExternalFileOpenStore.didReceiveFilesNotification)) { _ in
            handleExternalFileOpenRequest()
        }
        .onChange(of: editorErrorCheckingEnabled) { isEnabled in
            model.setErrorCheckingEnabled(isEnabled)
        }
        .task {
            handleExternalFileOpenRequest()
            restoreOpenTabsIfNeeded()
            model.setErrorCheckingEnabled(editorErrorCheckingEnabled)
        }
        .background(WindowConfigurationView(model: model, windowID: windowID))
    }

    private func restoreOpenTabsIfNeeded() {
        guard !ExternalFileOpenStore.shared.hasPendingPaths else {
            OpenTabsStore.shared.skipRestore()
            return
        }

        let restorePaths = OpenTabsStore.shared.consumeRestorePaths(isEnabled: restoreOpenTabsOnLaunch)
        guard !restorePaths.isEmpty else { return }

        if model.currentFileURL == nil {
            model.openFile(at: URL(fileURLWithPath: restorePaths[0]))
        }

        for filePath in restorePaths.dropFirst() {
            openWindow(value: filePath)
        }
    }

    private func handleExternalFileOpenRequest() {
        let paths = Array(NSOrderedSet(array: ExternalFileOpenStore.shared.consumePendingPaths())) as? [String] ?? []
        guard !paths.isEmpty else { return }

        var unopenedPaths: [String] = []

        for filePath in paths {
            if OpenTabsStore.shared.activateWindow(for: filePath) {
                continue
            }
            unopenedPaths.append(filePath)
        }

        guard !unopenedPaths.isEmpty else {
            return
        }

        if model.currentFileURL == nil && !model.hasUnsavedChanges {
            model.openFile(at: URL(fileURLWithPath: unopenedPaths[0]))

            for filePath in unopenedPaths.dropFirst() {
                openWindow(value: filePath)
            }
            return
        }

        for filePath in unopenedPaths {
            openWindow(value: filePath)
        }
    }
}

private extension ContentView {
    @ViewBuilder
    func toolbarButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 2)
    }

    var editorSection: some View {
        EditorTextView(
            text: $model.text,
            diagnostics: model.diagnostics,
            commandNames: model.commandNames,
            fontName: editorFontName,
            fontSize: CGFloat(editorFontSize),
            showsLineNumbers: showLineNumbers,
            indentationUnit: resolvedIndentationStyle.indentUnit,
            baseColorHex: editorBaseColorHex,
            keywordColorHex: editorKeywordColorHex,
            numberColorHex: editorNumberColorHex,
            variableColorHex: editorVariableColorHex,
            commentColorHex: editorCommentColorHex,
            errorUnderlineColorHex: editorErrorUnderlineColorHex,
            onTextChange: {
                model.scheduleValidation()
            },
            onSelectionChange: { line, column in
                model.cursorLine = line
                model.cursorColumn = column
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .clipped()
        .background(Color(NSColor.textBackgroundColor))
    }

    private var resolvedIndentationStyle: EditorIndentationStyle {
        EditorIndentationStyle(rawValue: editorIndentationStyleRawValue) ?? .fourSpaces
    }

    @ViewBuilder
    var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiagnosticsView(diagnostics: model.diagnostics, isErrorCheckingEnabled: editorErrorCheckingEnabled)

            if !model.lastRunOutput.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run Output")
                        .font(.headline)

                    TextEditor(text: .constant(model.lastRunOutput))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 120)
                        .disabled(true)
                        .border(Color.gray.opacity(0.2))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .frame(maxHeight: model.lastRunOutput.isEmpty ? 96 : 220, alignment: .top)
        .padding(12)
    }

    var statusBarSection: some View {
        HStack(spacing: 12) {
            Text("Line \(model.cursorLine), Column \(model.cursorColumn)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if let currentFileURL = model.currentFileURL {
                Text(currentFileURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Unsaved Document")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct DiagnosticsView: View {
    let diagnostics: [Diagnostic]
    let isErrorCheckingEnabled: Bool

    var body: some View {
        if !isErrorCheckingEnabled {
            Text("Error checking is disabled")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if diagnostics.isEmpty {
            Text("No syntax errors detected")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diagnostics) { diagnostic in
                    Text("Line \(diagnostic.line): \(diagnostic.message)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct WindowConfigurationView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    let windowID: String

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, windowID: windowID)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.attach(to: nsView)
        context.coordinator.refreshWindowState()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var previousDelegate: NSWindowDelegate?
        var model: EditorModel
        let windowID: String

        init(model: EditorModel, windowID: String) {
            self.model = model
            self.windowID = windowID
        }

        func attach(to view: NSView) {
            guard let window = view.window, window !== self.window else {
                return
            }

            previousDelegate = window.delegate
            self.window = window
            window.delegate = self
            refreshWindowState()
        }

        func refreshWindowState() {
            guard let window else {
                return
            }

            window.tabbingIdentifier = "GraphicsScriptEditorTabs"
            window.tabbingMode = .preferred
            window.isDocumentEdited = model.hasUnsavedChanges
            window.title = model.documentTitle
            window.representedURL = model.currentFileURL
            OpenTabsStore.shared.update(windowID: windowID, filePath: model.currentFileURL?.path, window: window)
            OpenTabsStore.shared.registerRestoredWindow(window, filePath: model.currentFileURL?.path)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            model.confirmClose(actionName: "close")
        }

        func windowWillClose(_ notification: Notification) {
            if NSApp.windows.count > 1 {
                DispatchQueue.main.async {
                    guard OpenTabsStore.shared.shouldRemoveClosedTabs else {
                        return
                    }
                    OpenTabsStore.shared.remove(windowID: self.windowID)
                }
            }
            if let window, window.delegate === self {
                window.delegate = previousDelegate
            }
        }
    }
}
