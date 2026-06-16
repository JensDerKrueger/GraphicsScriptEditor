import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    static let defaultScriptText = "# Your graphics script\nquit\n"

    @Published var text: String = "" {
        didSet {
            updateDirtyState()
            refreshScriptCommandDefinitions()
        }
    }
    @Published var diagnostics: [Diagnostic] = []
    @Published var currentFileURL: URL?
    @Published var statusMessage: String = ""
    @Published var lastRunOutput: String = ""
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var commandNames: Set<String> = DSLCommandSet.commandNames()

    var documentTitle: String {
        currentFileURL?.lastPathComponent ?? "Untitled"
    }

    private var pendingValidation: DispatchWorkItem?
    private var pendingAutosave: DispatchWorkItem?
    private var lastSavedText = ""
    private var fileMonitorTimer: Timer?
    private var lastKnownFileModificationDate: Date?
    private var ignoredExternalModificationDate: Date?
    private var isPresentingExternalChangeAlert = false
    private var isCheckingExternalFileChange = false
    private var internalWriteSuppressionUntil: Date?
    private var validationGeneration = 0
    private var manualCommandDefinitionURL: URL?
    private var manualCommandDefinitions: [DSLCommandSet.CommandDefinition] = []
    private var scriptCommandDefinitionURL: URL?
    private var scriptCommandDefinitions: [DSLCommandSet.CommandDefinition] = []
    private var commandDefinitionDiagnostics: [Diagnostic] = []

    init(initialText: String = EditorModel.defaultScriptText, initialFileURL: URL? = nil) {
        text = initialText
        lastSavedText = text
        currentFileURL = initialFileURL
        refreshScriptCommandDefinitions()
        refreshCommandNames()
        validateNow()

        if let initialFileURL {
            refreshObservedFileState(for: initialFileURL)
            startMonitoringCurrentFile()
        }
    }

    func applyDocumentState(text newText: String, fileURL: URL?) {
        let normalizedText = normalizedLoadedText(newText)
        text = normalizedText
        currentFileURL = fileURL
        lastSavedText = normalizedText
        hasUnsavedChanges = false
        refreshScriptCommandDefinitions()
        validateNow()

        if let fileURL {
            RecentFilesStore.register(url: fileURL)
            refreshObservedFileState(for: fileURL)
            startMonitoringCurrentFile()
        } else {
            fileMonitorTimer?.invalidate()
            lastKnownFileModificationDate = nil
            ignoredExternalModificationDate = nil
        }
    }

    func updateDocumentFileURL(_ fileURL: URL?) {
        guard currentFileURL != fileURL else {
            return
        }

        currentFileURL = fileURL
        refreshScriptCommandDefinitions()
        validateNow()

        if let fileURL {
            RecentFilesStore.register(url: fileURL)
            refreshObservedFileState(for: fileURL)
            startMonitoringCurrentFile()
        } else {
            fileMonitorTimer?.invalidate()
            lastKnownFileModificationDate = nil
            ignoredExternalModificationDate = nil
        }
    }

    func scheduleValidation() {
        guard isErrorCheckingEnabled else {
            pendingValidation?.cancel()
            validationGeneration += 1
            diagnostics = []
            scheduleAutosaveIfNeeded()
            return
        }

        pendingValidation?.cancel()
        let snapshot = text
        validationGeneration += 1
        let generation = validationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.validate(snapshot: snapshot, generation: generation)
        }
        pendingValidation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        scheduleAutosaveIfNeeded()
    }

    func validateNow() {
        guard isErrorCheckingEnabled else {
            validationGeneration += 1
            diagnostics = []
            return
        }
        validationGeneration += 1
        validate(snapshot: text, generation: validationGeneration)
    }

    func setErrorCheckingEnabled(_ isEnabled: Bool) {
        if isEnabled {
            validateNow()
        } else {
            pendingValidation?.cancel()
            validationGeneration += 1
            diagnostics = []
        }
    }

    func correctIndentation(using indentationUnit: String) {
        let updatedText = reindentedText(text, indentationUnit: indentationUnit)
        guard updatedText != text else {
            statusMessage = "Indentation already correct"
            return
        }

        text = updatedText
        statusMessage = "Corrected indentation"
        scheduleValidation()
    }

    func loadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: GraphicsScriptFileType.filenameExtension) ?? GraphicsScriptFileType.contentType,
            .plainText
        ]
        panel.title = "Open Script"
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            openFile(at: url)
        }
    }

    func loadCommandDefinitionsFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: CommandDefinitionFile.filenameExtension) ?? .plainText,
            .plainText
        ]
        panel.title = "Open Command Definitions"
        panel.prompt = "Load"

        if panel.runModal() == .OK, let url = panel.url {
            loadManualCommandDefinitions(from: url)
        }
    }

    func openFile(at url: URL) {
        do {
            text = normalizedLoadedText(try String(contentsOf: url, encoding: .utf8))
            currentFileURL = url
            lastSavedText = text
            hasUnsavedChanges = false
            statusMessage = "Loaded \(url.lastPathComponent)"
            refreshScriptCommandDefinitions()
            validateNow()
            RecentFilesStore.register(url: url)
            refreshObservedFileState(for: url)
            startMonitoringCurrentFile()
        } catch {
            statusMessage = "Failed to load file: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveFile() -> Bool {
        if let url = currentFileURL {
            return writeFile(url)
        }
        return saveFileAs()
    }

    @discardableResult
    func saveFileAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Script"
        panel.prompt = "Save"
        panel.allowedContentTypes = [GraphicsScriptFileType.contentType]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "script.gsc"

        if panel.runModal() == .OK, let url = panel.url {
            currentFileURL = url
            let result = writeFile(url)
            if result {
                refreshObservedFileState(for: url)
                startMonitoringCurrentFile()
            }
            return result
        }
        return false
    }

    func runScript() {
        guard let scriptURL = ensureSavedForRun() else {
            return
        }

        statusMessage = "Running..."
        lastRunOutput = ""

        let runnerPath = UserDefaults.standard.string(forKey: SettingsKeys.runnerPath) ?? ""
        let runnerURL = SecurityScopedAccess.resolvedURL(defaultsKey: SettingsKeys.runnerBookmark)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ScriptRunner.run(
                programPath: runnerPath,
                runnerURL: runnerURL,
                scriptURL: scriptURL
            )
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    self?.statusMessage = "Run finished"
                    self?.lastRunOutput = output
                case .failure(let error):
                    self?.statusMessage = "Run failed"
                    self?.lastRunOutput = error.localizedDescription
                }
            }
        }

    }

    func prepareForDocumentSaveAttempt() {
        suppressExternalChangeDetection()
    }

    func finalizeDocumentSave(fileURL: URL?) {
        lastSavedText = text
        hasUnsavedChanges = false

        if let fileURL {
            currentFileURL = fileURL
            RecentFilesStore.register(url: fileURL)
            refreshObservedFileState(for: fileURL)
            startMonitoringCurrentFile()
            statusMessage = "Saved \(fileURL.lastPathComponent)"
        } else {
            statusMessage = "Saved"
        }
    }

    private func ensureSavedForRun() -> URL? {
        if let url = currentFileURL, !hasUnsavedChanges {
            return url
        }

        return createTemporaryRunFile()
    }

    private func loadManualCommandDefinitions(from url: URL) {
        let result = CommandDefinitionFile.load(from: url)
        guard result.issues.isEmpty else {
            manualCommandDefinitionURL = nil
            manualCommandDefinitions = []
            commandDefinitionDiagnostics = diagnostics(for: result.issues, sourceURL: url)
            refreshCommandNames()
            validateNow()
            statusMessage = "Could not load \(url.lastPathComponent)"
            return
        }

        manualCommandDefinitionURL = url
        manualCommandDefinitions = result.definitions
        commandDefinitionDiagnostics = []
        refreshCommandNames()
        validateNow()
        statusMessage = "Loaded \(url.lastPathComponent)"
    }

    private func refreshScriptCommandDefinitions() {
        guard let referencedURL = firstCommandDefinitionURL(in: text, relativeTo: currentFileURL) else {
            if scriptCommandDefinitionURL != nil || !scriptCommandDefinitions.isEmpty {
                scriptCommandDefinitionURL = nil
                scriptCommandDefinitions = []
                commandDefinitionDiagnostics = []
                refreshCommandNames()
                validateNow()
            }
            return
        }

        guard referencedURL != scriptCommandDefinitionURL else {
            return
        }

        let result = CommandDefinitionFile.load(from: referencedURL)
        guard result.issues.isEmpty else {
            scriptCommandDefinitionURL = referencedURL
            scriptCommandDefinitions = []
            commandDefinitionDiagnostics = diagnostics(for: result.issues, sourceURL: referencedURL)
            refreshCommandNames()
            validateNow()
            statusMessage = "Could not load \(referencedURL.lastPathComponent)"
            return
        }

        scriptCommandDefinitionURL = referencedURL
        scriptCommandDefinitions = result.definitions
        commandDefinitionDiagnostics = []
        refreshCommandNames()
        validateNow()
        statusMessage = "Loaded \(referencedURL.lastPathComponent)"
    }

    private func refreshCommandNames() {
        commandNames = DSLCommandSet.commandNames(extraDefinitions: activeCommandDefinitions)
    }

    private var activeCommandDefinitions: [DSLCommandSet.CommandDefinition] {
        mergeCommandDefinitions(manualCommandDefinitions + scriptCommandDefinitions)
    }

    private func mergeCommandDefinitions(_ definitions: [DSLCommandSet.CommandDefinition]) -> [DSLCommandSet.CommandDefinition] {
        var order: [String] = []
        var signaturesByName: [String: [[ArgType]]] = [:]
        var seenSignatures: Set<String> = []

        for definition in definitions {
            if signaturesByName[definition.name] == nil {
                order.append(definition.name)
                signaturesByName[definition.name] = []
            }

            for signature in definition.signatures {
                let key = "\(definition.name)(\(signature.map(typeName).joined(separator: ",")))"
                guard !seenSignatures.contains(key) else {
                    continue
                }
                seenSignatures.insert(key)
                signaturesByName[definition.name]?.append(signature)
            }
        }

        return order.compactMap { name in
            guard let signatures = signaturesByName[name] else {
                return nil
            }
            return DSLCommandSet.CommandDefinition(name: name, signatures: signatures)
        }
    }

    private func firstCommandDefinitionURL(in script: String, relativeTo scriptURL: URL?) -> URL? {
        guard let rawReference = firstCommentText(in: script) else {
            return nil
        }

        let reference = trimmedPathReference(rawReference)
        guard !reference.isEmpty else {
            return nil
        }

        return resolvedCommandDefinitionURL(for: reference, relativeTo: scriptURL)
    }

    private func firstCommentText(in script: String) -> String? {
        for line in script.components(separatedBy: .newlines) {
            guard let hashIndex = line.firstIndex(of: "#") else {
                continue
            }

            let commentStart = line.index(after: hashIndex)
            return String(line[commentStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func trimmedPathReference(_ reference: String) -> String {
        var trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("commands:") {
            trimmed = String(trimmed.dropFirst("commands:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.count >= 2,
           let first = trimmed.first,
           let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        return trimmed
    }

    private func resolvedCommandDefinitionURL(for reference: String, relativeTo scriptURL: URL?) -> URL? {
        let expandedReference = (reference as NSString).expandingTildeInPath
        let candidateURL: URL

        if expandedReference.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: expandedReference)
        } else if let scriptURL {
            candidateURL = scriptURL.deletingLastPathComponent().appendingPathComponent(expandedReference)
        } else {
            candidateURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expandedReference)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        return candidateURL
    }

    private func diagnostics(for issues: [CommandDefinitionFile.ParseIssue], sourceURL: URL) -> [Diagnostic] {
        issues.map { issue in
            Diagnostic(
                line: 1,
                message: "\(sourceURL.lastPathComponent) line \(issue.line): \(issue.message)",
                code: .invalidArguments
            )
        }
    }

    private func typeName(_ type: ArgType) -> String {
        switch type {
        case .int:
            return "int"
        case .int64:
            return "int64"
        case .uint32:
            return "uint32"
        case .bool:
            return "bool"
        case .float:
            return "float"
        case .double:
            return "double"
        case .string:
            return "string"
        case .restString:
            return "restString"
        }
    }

    @discardableResult
    private func writeFile(_ url: URL) -> Bool {
        writeFile(url, updateStatus: true)
    }

    @discardableResult
    private func writeFile(_ url: URL, updateStatus: Bool) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            suppressExternalChangeDetection()
            lastSavedText = text
            hasUnsavedChanges = false
            RecentFilesStore.register(url: url)
            refreshObservedFileState(for: url)
            if updateStatus {
                statusMessage = "Saved \(url.lastPathComponent)"
            }
            return true
        } catch {
            statusMessage = "Failed to save file: \(error.localizedDescription)"
            return false
        }
    }

    private func scheduleAutosaveIfNeeded() {
        pendingAutosave?.cancel()

        let interval = UserDefaults.standard.double(forKey: SettingsKeys.editorAutosaveInterval)
        guard interval > 0, let url = currentFileURL, hasUnsavedChanges else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.writeFile(url, updateStatus: false)
        }
        pendingAutosave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    func confirmClose(actionName: String) -> Bool {
        guard hasUnsavedChanges else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \"\(documentTitle)\"?"
        alert.informativeText = "Your unsaved changes will be lost if you \(actionName) without saving."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveFile()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    private func updateDirtyState() {
        hasUnsavedChanges = text != lastSavedText
    }

    private func startMonitoringCurrentFile() {
        fileMonitorTimer?.invalidate()
        guard currentFileURL != nil else {
            return
        }

        fileMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForExternalFileChanges()
        }
    }

    private func refreshObservedFileState(for url: URL) {
        lastKnownFileModificationDate = fileModificationDate(for: url)
        ignoredExternalModificationDate = nil
    }

    private func checkForExternalFileChanges() {
        guard let currentFileURL,
              !isPresentingExternalChangeAlert,
              !isCheckingExternalFileChange,
              let currentModificationDate = fileModificationDate(for: currentFileURL) else {
            return
        }

        if let internalWriteSuppressionUntil, Date() < internalWriteSuppressionUntil {
            lastKnownFileModificationDate = currentModificationDate
            return
        }

        internalWriteSuppressionUntil = nil

        if let lastKnownFileModificationDate, currentModificationDate <= lastKnownFileModificationDate {
            return
        }

        if let ignoredExternalModificationDate, currentModificationDate <= ignoredExternalModificationDate {
            return
        }

        let currentText = text
        let savedText = lastSavedText
        isCheckingExternalFileChange = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let diskText = self?.fileContents(for: currentFileURL)

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.isCheckingExternalFileChange = false

                guard self.currentFileURL == currentFileURL,
                      !self.isPresentingExternalChangeAlert else {
                    return
                }

                guard let latestModificationDate = self.fileModificationDate(for: currentFileURL),
                      latestModificationDate >= currentModificationDate else {
                    return
                }

                guard let diskText else {
                    return
                }

                if diskText == currentText {
                    self.lastSavedText = currentText
                    self.hasUnsavedChanges = false
                    self.lastKnownFileModificationDate = latestModificationDate
                    self.ignoredExternalModificationDate = nil
                    return
                }

                if diskText == savedText {
                    self.lastKnownFileModificationDate = latestModificationDate
                    self.ignoredExternalModificationDate = nil
                    return
                }

                self.presentExternalChangeAlert(for: currentFileURL, modificationDate: latestModificationDate)
            }
        }
    }

    private func presentExternalChangeAlert(for url: URL, modificationDate: Date) {
        isPresentingExternalChangeAlert = true

        let alert = NSAlert()
        alert.messageText = "\"\(url.lastPathComponent)\" changed on disk."
        alert.informativeText = hasUnsavedChanges
            ? "The file was modified by another program. Reloading will discard your unsaved changes."
            : "The file was modified by another program. Do you want to reload it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Ignore")

        let response = alert.runModal()
        isPresentingExternalChangeAlert = false

        if response == .alertFirstButtonReturn {
            openFile(at: url)
        } else {
            ignoredExternalModificationDate = modificationDate
            lastKnownFileModificationDate = modificationDate
            statusMessage = "Ignored external change to \(url.lastPathComponent)"
        }
    }

    private func fileModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fileContents(for url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func suppressExternalChangeDetection() {
        internalWriteSuppressionUntil = Date().addingTimeInterval(2.0)
    }

    private func createTemporaryRunFile() -> URL? {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphicsScriptEditorRuns", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: true
            )

            let baseName = currentFileURL?.deletingPathExtension().lastPathComponent ?? "script"
            let temporaryFileURL = temporaryDirectoryURL
                .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
                .appendingPathExtension(GraphicsScriptFileType.filenameExtension)

            try text.write(to: temporaryFileURL, atomically: true, encoding: .utf8)
            statusMessage = currentFileURL == nil
                ? "Running unsaved script"
                : "Running unsaved changes from temporary copy"
            return temporaryFileURL
        } catch {
            statusMessage = "Failed to prepare script for run: \(error.localizedDescription)"
            return nil
        }
    }

    private var isErrorCheckingEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.editorErrorCheckingEnabled) as? Bool ?? true
    }

    private func normalizedLoadedText(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    private func reindentedText(_ text: String, indentationUnit: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var indentationLevel = 0

        let adjustedLines = lines.map { line -> String in
            let trimmedLeading = line.replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression)
            let command = indentationCommand(for: trimmedLeading)
            let isBlankLine = trimmedLeading.isEmpty

            if DSLCommandSet.blockClosingCommands.contains(command) {
                indentationLevel = max(0, indentationLevel - 1)
            }

            let indentedLine: String
            if isBlankLine {
                indentedLine = ""
            } else {
                indentedLine = String(repeating: indentationUnit, count: indentationLevel) + trimmedLeading
            }

            if DSLCommandSet.blockOpeningCommands.contains(command) {
                indentationLevel += 1
            }

            return indentedLine
        }

        return adjustedLines.joined(separator: "\n")
    }

    private func indentationCommand(for line: String) -> String {
        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        return content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
    }

    private func validate(snapshot: String, generation: Int) {
        let commandDefinitions = activeCommandDefinitions
        let definitionDiagnostics = commandDefinitionDiagnostics

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diagnostics = definitionDiagnostics.isEmpty
                ? DSLValidator(commandDefinitions: commandDefinitions).validate(snapshot)
                : definitionDiagnostics
            DispatchQueue.main.async {
                guard let self,
                      self.isErrorCheckingEnabled,
                      self.validationGeneration == generation,
                      self.text == snapshot else {
                    return
                }
                self.diagnostics = diagnostics
            }
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
