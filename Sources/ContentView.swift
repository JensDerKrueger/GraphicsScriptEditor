import SwiftUI
import AppKit

struct ContentView: View {
    @Binding private var document: GraphicsScriptDocument
    @StateObject private var model: EditorModel
    @AppStorage(SettingsKeys.editorFontName) private var editorFontName: String = "Menlo"
    @AppStorage(SettingsKeys.editorFontSize) private var editorFontSize: Double = 13
    @AppStorage(SettingsKeys.showLineNumbers) private var showLineNumbers = true
    @AppStorage(SettingsKeys.editorIndentationStyle) private var editorIndentationStyleRawValue = EditorIndentationStyle.fourSpaces.rawValue
    @AppStorage(SettingsKeys.editorErrorCheckingEnabled) private var editorErrorCheckingEnabled = true
    @AppStorage(SettingsKeys.editorBaseColor) private var editorBaseColorHex: String = ""
    @AppStorage(SettingsKeys.editorKeywordColor) private var editorKeywordColorHex: String = ""
    @AppStorage(SettingsKeys.editorNumberColor) private var editorNumberColorHex: String = ""
    @AppStorage(SettingsKeys.editorVariableColor) private var editorVariableColorHex: String = ""
    @AppStorage(SettingsKeys.editorCommentColor) private var editorCommentColorHex: String = ""
    @AppStorage(SettingsKeys.editorErrorUnderlineColor) private var editorErrorUnderlineColorHex: String = ""
    @Environment(\.documentConfiguration) private var documentConfiguration

    init(document: Binding<GraphicsScriptDocument>, fileURL: URL?) {
        _document = document
        _model = StateObject(
            wrappedValue: EditorModel(
                initialText: document.wrappedValue.text,
                initialFileURL: fileURL
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    openDocument()
                } label: {
                    toolbarButtonLabel("Open", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    saveDocument()
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
        .onChange(of: editorErrorCheckingEnabled) { _, isEnabled in
            model.setErrorCheckingEnabled(isEnabled)
        }
        .onChange(of: document.text) { _, newText in
            guard model.text != newText else {
                return
            }

            model.applyDocumentState(text: newText, fileURL: documentConfiguration?.fileURL)
        }
        .onChange(of: model.text) { _, newText in
            guard document.text != newText else {
                return
            }

            document.text = newText
        }
        .onChange(of: documentConfiguration?.fileURL) { _, newFileURL in
            model.updateDocumentFileURL(newFileURL)
        }
        .task {
            model.setErrorCheckingEnabled(editorErrorCheckingEnabled)
            model.updateDocumentFileURL(documentConfiguration?.fileURL)
        }
    }
}

private extension ContentView {
    func openDocument() {
        DocumentActionController.openDocument()
    }

    func saveDocument() {
        DocumentActionController.saveCurrentDocument(using: model)
    }

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


/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use, copy,
 modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 to permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
