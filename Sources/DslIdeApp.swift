import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum GraphicsScriptFileType {
    static let typeIdentifier = "de.cgvis.graphicsscript"
    static let filenameExtension = "gsc"
    static let contentType = UTType(exportedAs: typeIdentifier)
}

enum AppIconLoader {
    static func apply() {
        guard let iconURL = Bundle.main.url(forResource: "AppRuntimeIcon", withExtension: "png"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApp.applicationIconImage = iconImage
    }
}

struct RecentFilesStore {
    static let defaultsKey = "recentGraphicsScriptFiles"

    static var filePaths: [String] {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return paths.filter { !$0.isEmpty }
    }

    static func register(url: URL) {
        var paths = filePaths
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: defaultsKey)
    }
}

struct OpenDocumentStateStore {
    static let defaultsKey = "openGraphicsScriptDocumentPaths"

    static var fileURLs: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return paths
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    static func persistCurrentDocuments() {
        let paths = NSDocumentController.shared.documents
            .compactMap(\.fileURL)
            .map(\.path)
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }
}

final class GraphicsScriptEditorAppDelegate: NSObject, NSApplicationDelegate {
    private var didReceiveExternalOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.setActivationPolicy(.regular)
        AppIconLoader.apply()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            self?.restoreOpenDocumentsIfNeeded()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenDocumentStateStore.persistCurrentDocuments()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        didReceiveExternalOpen = !urls.isEmpty
    }

    private func restoreOpenDocumentsIfNeeded() {
        guard !didReceiveExternalOpen else {
            return
        }

        for fileURL in OpenDocumentStateStore.fileURLs {
            NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, error in
                if let error {
                    NSLog("Failed to restore graphics script document: %@", error.localizedDescription)
                }
            }
        }
    }
}

@MainActor
private final class SaveContext: NSObject {
    weak var model: EditorModel?

    init(model: EditorModel?) {
        self.model = model
    }
}

@MainActor
enum DocumentActionController {
    private final class SaveDelegate: NSObject {
        @objc
        @MainActor
        func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
            guard let contextInfo else {
                return
            }

            let context = Unmanaged<SaveContext>.fromOpaque(contextInfo).takeRetainedValue()
            guard didSave else {
                return
            }

            context.model?.finalizeDocumentSave(fileURL: document.fileURL)
        }
    }

    private static let saveDelegate = SaveDelegate()

    static func openDocument() {
        NSApp.sendAction(#selector(NSDocumentController.openDocument(_:)), to: nil, from: nil)
    }

    static func saveCurrentDocument(using model: EditorModel?) {
        guard let document = NSDocumentController.shared.currentDocument else {
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            return
        }

        model?.prepareForDocumentSaveAttempt()
        let context = Unmanaged.passRetained(SaveContext(model: model)).toOpaque()
        document.save(
            withDelegate: saveDelegate,
            didSave: #selector(SaveDelegate.document(_:didSave:contextInfo:)),
            contextInfo: context
        )
    }

    static func saveCurrentDocumentAs() {
        NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil)
    }
}

struct EditorMenuCommands: Commands {
    @FocusedObject private var model: EditorModel?
    @AppStorage(SettingsKeys.editorIndentationStyle) private var editorIndentationStyleRawValue = EditorIndentationStyle.fourSpaces.rawValue

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("Open Recent") {
                if RecentFilesStore.filePaths.isEmpty {
                    Text("No Recent Files")
                } else {
                    ForEach(RecentFilesStore.filePaths, id: \.self) { filePath in
                        Button(URL(fileURLWithPath: filePath).lastPathComponent) {
                            openRecentFile(at: filePath)
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Script") {
                DocumentActionController.saveCurrentDocument(using: model)
            }
            .keyboardShortcut("s")
            .disabled(model == nil)

            Button("Save Script As…") {
                DocumentActionController.saveCurrentDocumentAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find…") {
                sendTextFinderAction(.showFindInterface)
            }
            .keyboardShortcut("f")

            Button("Find and Replace…") {
                sendTextFinderAction(.showReplaceInterface)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button("Find Next") {
                sendTextFinderAction(.nextMatch)
            }
            .keyboardShortcut("g")

            Button("Find Previous") {
                sendTextFinderAction(.previousMatch)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandMenu("Script") {
            Button("Run Script") {
                model?.runScript()
            }
            .keyboardShortcut("r")
            .disabled(model == nil)

            Button("Correct Indentation") {
                model?.correctIndentation(using: resolvedIndentationStyle.indentUnit)
            }
            .disabled(model == nil)
        }
    }

    private var resolvedIndentationStyle: EditorIndentationStyle {
        EditorIndentationStyle(rawValue: editorIndentationStyleRawValue) ?? .fourSpaces
    }

    private func openRecentFile(at filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else {
                return
            }

            NSSound.beep()
            NSLog("Failed to open recent graphics script: %@", error.localizedDescription)
        }
    }

    private func sendTextFinderAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}

@main
struct GraphicsScriptEditorApp: App {
    @NSApplicationDelegateAdaptor(GraphicsScriptEditorAppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: GraphicsScriptDocument()) { configuration in
            ContentView(
                document: configuration.$document,
                fileURL: configuration.fileURL
            )
        }
        .commands {
            EditorMenuCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
