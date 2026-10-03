import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    static var defaultScriptText: String {
        "# \(String(localized: "Your graphics script"))\nquit\n"
    }

    @Published var text: String = "" {
        didSet {
            updateDirtyState()
            refreshScriptCommandDefinitions()
        }
    }
    @Published var diagnostics: [Diagnostic] = []
    @Published var currentFileURL: URL?
    @Published var statusMessage: String = ""
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var commandNames: Set<String> = DSLCommandSet.commandNames()
    @Published private(set) var valueFunctionNames: Set<String> = []

    var documentTitle: String {
        currentFileURL?.lastPathComponent ?? String(localized: "Untitled")
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
    private var fileObservationGeneration = 0
    private var validationGeneration = 0
    private var manualCommandDefinitionURL: URL?
    private var manualCommandDefinitions: [DSLCommandSet.CommandDefinition] = []
    private var scriptCommandDefinitionURL: URL?
    private var scriptCommandDefinitions: [DSLCommandSet.CommandDefinition] = []
    private var commandDefinitionDiagnostics: [Diagnostic] = []
    private var commandDefinitionAccessPanel: NSOpenPanel?
    private var promptedCommandDefinitionURL: URL?

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
            clearObservedFileState()
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
            reconcileSavedStateIfNeeded(for: fileURL)
            refreshObservedFileState(for: fileURL)
            startMonitoringCurrentFile()
        } else {
            fileMonitorTimer?.invalidate()
            clearObservedFileState()
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
            statusMessage = String(localized: "Indentation already correct")
            return
        }

        text = updatedText
        statusMessage = String(localized: "Corrected indentation")
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
        panel.title = String(localized: "Open Script")
        panel.prompt = String(localized: "Open")

        if panel.runModal() == .OK, let url = panel.url {
            openFile(at: url)
        }
    }

    func loadCommandDefinitionsFromPanel() {
        let panel = makeCommandDefinitionOpenPanel()

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
            statusMessage = String(format: String(localized: "Loaded %@"), url.lastPathComponent)
            refreshScriptCommandDefinitions()
            validateNow()
            RecentFilesStore.register(url: url)
            refreshObservedFileState(for: url)
            startMonitoringCurrentFile()
        } catch {
            statusMessage = String(format: String(localized: "Failed to load file: %@"), error.localizedDescription)
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
        panel.title = String(localized: "Save Script")
        panel.prompt = String(localized: "Save")
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

    func prepareForDocumentSaveAttempt() {
        suppressExternalChangeDetection()
    }

    func finalizeDocumentSave(fileURL: URL?) {
        suppressExternalChangeDetection()
        lastSavedText = text
        hasUnsavedChanges = false

        if let fileURL {
            currentFileURL = fileURL
            RecentFilesStore.register(url: fileURL)
            refreshObservedFileState(for: fileURL)
            startMonitoringCurrentFile()
            statusMessage = String(format: String(localized: "Saved %@"), fileURL.lastPathComponent)
        } else {
            statusMessage = String(localized: "Saved")
        }
    }

    private func loadManualCommandDefinitions(from url: URL) {
        let result = CommandDefinitionFile.load(from: url)
        guard result.issues.isEmpty else {
            manualCommandDefinitionURL = nil
            manualCommandDefinitions = []
            commandDefinitionDiagnostics = diagnostics(for: result.issues, sourceURL: url)
            refreshCommandNames()
            validateNow()
            statusMessage = String(format: String(localized: "Could not load %@"), url.lastPathComponent)
            return
        }

        manualCommandDefinitionURL = url
        manualCommandDefinitions = result.definitions
        commandDefinitionDiagnostics = []
        refreshCommandNames()
        validateNow()
        statusMessage = String(format: String(localized: "Loaded %@"), url.lastPathComponent)
    }

    private func refreshScriptCommandDefinitions() {
        guard let referencedURL = firstCommandDefinitionURL(in: text, relativeTo: currentFileURL) else {
            if scriptCommandDefinitionURL != nil || !scriptCommandDefinitions.isEmpty {
                scriptCommandDefinitionURL = nil
                scriptCommandDefinitions = []
                commandDefinitionDiagnostics = []
                promptedCommandDefinitionURL = nil
                refreshCommandNames()
                validateNow()
            }
            return
        }

        guard referencedURL != scriptCommandDefinitionURL else {
            return
        }

        let accessibleURL = SecurityScopedAccess.resolvedURL(
            defaultsKey: commandDefinitionBookmarkKey(for: referencedURL)
        ) ?? referencedURL
        loadScriptCommandDefinitions(from: accessibleURL, referencedBy: referencedURL)
    }

    private func loadScriptCommandDefinitions(from accessibleURL: URL, referencedBy referencedURL: URL) {
        let result = CommandDefinitionFile.load(from: accessibleURL)
        guard result.issues.isEmpty else {
            scriptCommandDefinitionURL = referencedURL
            scriptCommandDefinitions = []
            commandDefinitionDiagnostics = diagnostics(for: result.issues, sourceURL: accessibleURL)
            refreshCommandNames()
            validateNow()
            statusMessage = String(format: String(localized: "Could not load %@"), referencedURL.lastPathComponent)
            if result.sourceReadFailed {
                requestAccessToCommandDefinitions(at: referencedURL)
            }
            return
        }

        scriptCommandDefinitionURL = referencedURL
        scriptCommandDefinitions = result.definitions
        commandDefinitionDiagnostics = []
        refreshCommandNames()
        validateNow()
        statusMessage = String(format: String(localized: "Loaded %@"), referencedURL.lastPathComponent)
    }

    private func requestAccessToCommandDefinitions(at referencedURL: URL) {
        guard commandDefinitionAccessPanel == nil,
              promptedCommandDefinitionURL != referencedURL else {
            return
        }

        promptedCommandDefinitionURL = referencedURL

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.commandDefinitionAccessPanel == nil,
                  self.firstCommandDefinitionURL(in: self.text, relativeTo: self.currentFileURL) == referencedURL else {
                return
            }

            let explanation = NSAlert()
            explanation.alertStyle = .informational
            explanation.messageText = String(localized: "Command Definitions Require Access")
            explanation.informativeText = String(
                format: String(localized: "The script references %@. Because the app runs in the macOS sandbox, select this file in the next dialog to allow the editor to load its command definitions. You can decline, but the definition file will not be loaded and commands defined in it may be incorrectly reported as errors."),
                referencedURL.lastPathComponent
            )
            explanation.addButton(withTitle: String(localized: "Continue"))
            explanation.addButton(withTitle: String(localized: "Don't Load"))

            guard explanation.runModal() == .alertFirstButtonReturn,
                  self.firstCommandDefinitionURL(in: self.text, relativeTo: self.currentFileURL) == referencedURL else {
                return
            }

            let panel = self.makeCommandDefinitionOpenPanel()
            panel.message = String(
                format: String(localized: "The script references %@. Select this command definition file to load it."),
                referencedURL.lastPathComponent
            )
            panel.directoryURL = referencedURL.deletingLastPathComponent()
            panel.nameFieldStringValue = referencedURL.lastPathComponent
            self.commandDefinitionAccessPanel = panel

            panel.begin { [weak self, weak panel] response in
                guard let self, let panel,
                      self.commandDefinitionAccessPanel === panel else {
                    return
                }
                self.commandDefinitionAccessPanel = nil

                guard self.firstCommandDefinitionURL(in: self.text, relativeTo: self.currentFileURL) == referencedURL else {
                    self.scriptCommandDefinitionURL = nil
                    self.refreshScriptCommandDefinitions()
                    return
                }

                guard response == .OK, let selectedURL = panel.url else {
                    return
                }

                SecurityScopedAccess.storeBookmark(
                    for: selectedURL,
                    defaultsKey: self.commandDefinitionBookmarkKey(for: referencedURL)
                )
                self.loadScriptCommandDefinitions(from: selectedURL, referencedBy: referencedURL)
            }
        }
    }

    private func makeCommandDefinitionOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: CommandDefinitionFile.filenameExtension) ?? .plainText
        ]
        panel.title = String(localized: "Open Command Definitions")
        panel.prompt = String(localized: "Load")
        return panel
    }

    private func commandDefinitionBookmarkKey(for referencedURL: URL) -> String {
        let pathData = Data(referencedURL.standardizedFileURL.path.utf8)
        return "commandDefinitionBookmark.\(pathData.base64EncodedString())"
    }

    private func refreshCommandNames() {
        commandNames = DSLCommandSet.commandNames(extraDefinitions: activeCommandDefinitions)
        valueFunctionNames = DSLCommandSet.valueFunctionNames(extraDefinitions: activeCommandDefinitions)
    }

    private var activeCommandDefinitions: [DSLCommandSet.CommandDefinition] {
        mergeCommandDefinitions(manualCommandDefinitions + scriptCommandDefinitions)
    }

    private func mergeCommandDefinitions(_ definitions: [DSLCommandSet.CommandDefinition]) -> [DSLCommandSet.CommandDefinition] {
        var order: [String] = []
        var signaturesByIdentity: [String: [[ArgType]]] = [:]
        var metadataByIdentity: [String: (name: String, returnType: ArgType?)] = [:]
        var seenSignatures: Set<String> = []

        for definition in definitions {
            let returnTypeName = definition.returnType.map(typeName) ?? "command"
            let identity = "\(definition.name)->\(returnTypeName)"

            if signaturesByIdentity[identity] == nil {
                order.append(identity)
                signaturesByIdentity[identity] = []
                metadataByIdentity[identity] = (definition.name, definition.returnType)
            }

            for signature in definition.signatures {
                let key = "\(identity)(\(signature.map(typeName).joined(separator: ",")))"
                guard !seenSignatures.contains(key) else {
                    continue
                }
                seenSignatures.insert(key)
                signaturesByIdentity[identity]?.append(signature)
            }
        }

        return order.compactMap { identity in
            guard let signatures = signaturesByIdentity[identity],
                  let metadata = metadataByIdentity[identity] else {
                return nil
            }
            return DSLCommandSet.CommandDefinition(
                name: metadata.name,
                signatures: signatures,
                returnType: metadata.returnType
            )
        }
    }

    private func firstCommandDefinitionURL(in script: String, relativeTo scriptURL: URL?) -> URL? {
        guard let rawReference = firstCommentText(in: script) else {
            return nil
        }

        let reference = trimmedPathReference(rawReference)
        guard !reference.isEmpty,
              (reference as NSString).pathExtension.lowercased() == CommandDefinitionFile.filenameExtension else {
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

        return candidateURL.standardizedFileURL
    }

    private func diagnostics(for issues: [CommandDefinitionFile.ParseIssue], sourceURL: URL) -> [Diagnostic] {
        issues.map { issue in
            Diagnostic(
                line: 1,
                message: String(format: String(localized: "%@ line %lld: %@"), sourceURL.lastPathComponent, issue.line, issue.message),
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
            suppressExternalChangeDetection()
            try text.write(to: url, atomically: true, encoding: .utf8)
            suppressExternalChangeDetection()
            lastSavedText = text
            hasUnsavedChanges = false
            RecentFilesStore.register(url: url)
            refreshObservedFileState(for: url)
            if updateStatus {
                statusMessage = String(format: String(localized: "Saved %@"), url.lastPathComponent)
            }
            return true
        } catch {
            statusMessage = String(format: String(localized: "Failed to save file: %@"), error.localizedDescription)
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
        alert.messageText = String(format: String(localized: "Do you want to save the changes made to \"%@\"?"), documentTitle)
        alert.informativeText = String(format: String(localized: "Your unsaved changes will be lost if you %@ without saving."), actionName)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don't Save"))

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
        fileObservationGeneration += 1
        lastKnownFileModificationDate = fileModificationDate(for: url)
        ignoredExternalModificationDate = nil
    }

    private func clearObservedFileState() {
        fileObservationGeneration += 1
        lastKnownFileModificationDate = nil
        ignoredExternalModificationDate = nil
        internalWriteSuppressionUntil = nil
    }

    private func reconcileSavedStateIfNeeded(for url: URL) {
        guard let diskText = fileContents(for: url),
              normalizedLoadedText(diskText) == text else {
            return
        }

        lastSavedText = text
        hasUnsavedChanges = false
        suppressExternalChangeDetection()
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
        let observationGeneration = fileObservationGeneration
        isCheckingExternalFileChange = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let diskText = self?.fileContents(for: currentFileURL)

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.isCheckingExternalFileChange = false

                guard self.currentFileURL == currentFileURL,
                      self.fileObservationGeneration == observationGeneration,
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

                let normalizedDiskText = self.normalizedLoadedText(diskText)

                if normalizedDiskText == currentText {
                    self.lastSavedText = currentText
                    self.hasUnsavedChanges = false
                    self.lastKnownFileModificationDate = latestModificationDate
                    self.ignoredExternalModificationDate = nil
                    return
                }

                if normalizedDiskText == savedText {
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
        alert.messageText = String(format: String(localized: "\"%@\" changed on disk."), url.lastPathComponent)
        alert.informativeText = hasUnsavedChanges
            ? String(localized: "The file was modified by another program. Reloading will discard your unsaved changes.")
            : String(localized: "The file was modified by another program. Do you want to reload it?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.addButton(withTitle: String(localized: "Ignore"))

        let response = alert.runModal()
        isPresentingExternalChangeAlert = false

        if response == .alertFirstButtonReturn {
            openFile(at: url)
        } else {
            ignoredExternalModificationDate = modificationDate
            lastKnownFileModificationDate = modificationDate
            statusMessage = String(format: String(localized: "Ignored external change to %@"), url.lastPathComponent)
        }
    }

    private func fileModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fileContents(for url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func suppressExternalChangeDetection() {
        fileObservationGeneration += 1
        internalWriteSuppressionUntil = Date().addingTimeInterval(2.0)
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
