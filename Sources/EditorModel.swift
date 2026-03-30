import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    @Published var text: String = "" {
        didSet {
            updateDirtyState()
        }
    }
    @Published var diagnostics: [Diagnostic] = []
    @Published var currentFileURL: URL?
    @Published var statusMessage: String = ""
    @Published var lastRunOutput: String = ""
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    @Published private(set) var hasUnsavedChanges = false

    let commandNames: Set<String> = DSLCommandSet.commandNames

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
    private var internalWriteSuppressionUntil: Date?
    private var validationGeneration = 0

    init(initialFilePath: String? = nil) {
        text = "# Your graphics script\nquit\n"
        lastSavedText = text
        validateNow()

        if let initialFilePath, !initialFilePath.isEmpty {
            openFile(at: URL(fileURLWithPath: initialFilePath))
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

    func openFile(at url: URL) {
        do {
            text = normalizedLoadedText(try String(contentsOf: url, encoding: .utf8))
            currentFileURL = url
            lastSavedText = text
            hasUnsavedChanges = false
            statusMessage = "Loaded \(url.lastPathComponent)"
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

    private func ensureSavedForRun() -> URL? {
        if let url = currentFileURL {
            return writeFile(url) ? url : nil
        }

        let panel = NSSavePanel()
        panel.title = "Save Script"
        panel.prompt = "Save"
        panel.allowedContentTypes = [GraphicsScriptFileType.contentType]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "script.gsc"

        if panel.runModal() == .OK, let url = panel.url {
            currentFileURL = url
            let didWrite = writeFile(url)
            if didWrite {
                refreshObservedFileState(for: url)
                startMonitoringCurrentFile()
            }
            return didWrite ? url : nil
        }

        return nil
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

        presentExternalChangeAlert(for: currentFileURL, modificationDate: currentModificationDate)
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

    private func suppressExternalChangeDetection() {
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diagnostics = DSLValidator().validate(snapshot)
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
