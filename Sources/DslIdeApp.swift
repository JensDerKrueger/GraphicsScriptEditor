import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum GraphicsScriptFileType {
    static let typeIdentifier = "de.cgvis.graphicsscript"
    static let filenameExtension = "gsc"
    static let contentType = UTType(exportedAs: typeIdentifier)
}

@MainActor
final class ExternalFileOpenStore {
    static let shared = ExternalFileOpenStore()

    static let didReceiveFilesNotification = Notification.Name("ExternalFileOpenStoreDidReceiveFiles")

    private var pendingPaths: [String] = []

    func enqueue(urls: [URL]) {
        let paths = urls
            .filter { $0.isFileURL }
            .map(\.path)

        guard !paths.isEmpty else {
            return
        }

        pendingPaths.append(contentsOf: paths)
        NotificationCenter.default.post(name: Self.didReceiveFilesNotification, object: nil)
    }

    func consumePendingPaths() -> [String] {
        let paths = pendingPaths
        pendingPaths.removeAll()
        return paths
    }

    var hasPendingPaths: Bool {
        !pendingPaths.isEmpty
    }
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

@MainActor
final class OpenTabsStore {
    static let shared = OpenTabsStore()

    private static let defaultsKey = "openGraphicsScriptTabs"

    private final class WeakWindowBox {
        weak var window: NSWindow?

        init(window: NSWindow) {
            self.window = window
        }
    }

    private var openTabsByWindowID: [String: String] = [:]
    private var windowsByWindowID: [String: WeakWindowBox] = [:]
    private var restoreAttempted = false
    private var isTerminating = false
    private var pendingRestoreTabPaths: Set<String> = []
    private weak var primaryRestoreWindow: NSWindow?

    var persistedPaths: [String] {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        return paths.filter { !$0.isEmpty }
    }

    func update(windowID: String, filePath: String?, window: NSWindow?) {
        if let window {
            windowsByWindowID[windowID] = WeakWindowBox(window: window)
        } else {
            windowsByWindowID.removeValue(forKey: windowID)
        }

        if !restoreAttempted, (filePath == nil || filePath?.isEmpty == true) {
            return
        }

        if let filePath, !filePath.isEmpty {
            openTabsByWindowID[windowID] = filePath
        } else {
            openTabsByWindowID.removeValue(forKey: windowID)
        }
        persistCurrentTabs()
    }

    func remove(windowID: String) {
        guard !isTerminating else {
            return
        }
        openTabsByWindowID.removeValue(forKey: windowID)
        windowsByWindowID.removeValue(forKey: windowID)
        persistCurrentTabs()
    }

    func persistCurrentTabs() {
        UserDefaults.standard.set(Array(openTabsByWindowID.values), forKey: Self.defaultsKey)
    }

    func consumeRestorePaths(isEnabled: Bool) -> [String] {
        guard isEnabled, !restoreAttempted else {
            return []
        }

        restoreAttempted = true
        let paths = persistedPaths
        pendingRestoreTabPaths = Set(paths.dropFirst())
        primaryRestoreWindow = nil
        return paths
    }

    func skipRestore() {
        guard !restoreAttempted else {
            return
        }
        restoreAttempted = true
        pendingRestoreTabPaths = []
        primaryRestoreWindow = nil
    }

    func beginTermination() {
        isTerminating = true
    }

    var shouldRemoveClosedTabs: Bool {
        !isTerminating
    }

    func registerRestoredWindow(_ window: NSWindow, filePath: String?) {
        guard restoreAttempted else {
            return
        }

        guard let filePath, !filePath.isEmpty else {
            if primaryRestoreWindow == nil {
                primaryRestoreWindow = window
            }
            return
        }

        if primaryRestoreWindow == nil {
            primaryRestoreWindow = window
            pendingRestoreTabPaths.remove(filePath)
            return
        }

        guard pendingRestoreTabPaths.contains(filePath),
              let primaryRestoreWindow,
              primaryRestoreWindow !== window else {
            return
        }

        pendingRestoreTabPaths.remove(filePath)
        DispatchQueue.main.async {
            primaryRestoreWindow.addTabbedWindow(window, ordered: .above)
            primaryRestoreWindow.makeKeyAndOrderFront(nil)
        }
    }

    func activateWindow(for filePath: String) -> Bool {
        cleanupWindowRegistry()

        guard let windowID = openTabsByWindowID.first(where: { $0.value == filePath })?.key,
              let window = windowsByWindowID[windowID]?.window else {
            return false
        }

        if let tabGroup = window.tabGroup,
           let tab = tabGroup.windows.first(where: { $0 === window }) {
            tabGroup.selectedWindow = tab
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func cleanupWindowRegistry() {
        let activeWindowIDs = windowsByWindowID.compactMap { windowID, box in
            box.window == nil ? nil : windowID
        }
        let activeWindowIDSet = Set(activeWindowIDs)
        windowsByWindowID = windowsByWindowID.filter { $0.value.window != nil }
        openTabsByWindowID = openTabsByWindowID.filter { activeWindowIDSet.contains($0.key) }
    }
}

final class GraphicsScriptEditorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.setActivationPolicy(.regular)
        AppIconLoader.apply()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in sender.windows {
            guard let delegate = window.delegate as? WindowConfigurationView.Coordinator else {
                continue
            }

            if !delegate.model.confirmClose(actionName: "quit") {
                return .terminateCancel
            }
        }

        OpenTabsStore.shared.beginTermination()
        OpenTabsStore.shared.persistCurrentTabs()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalFileOpenStore.shared.enqueue(urls: urls)
    }
}

struct EditorMenuCommands: Commands {
    @FocusedObject private var model: EditorModel?
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKeys.editorIndentationStyle) private var editorIndentationStyleRawValue = EditorIndentationStyle.fourSpaces.rawValue

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Script…") {
                model?.loadFile()
            }
            .keyboardShortcut("o")
            .disabled(model == nil)

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
                model?.saveFile()
            }
            .keyboardShortcut("s")
            .disabled(model == nil)

            Button("Save Script As…") {
                model?.saveFileAs()
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
        if let model {
            model.openFile(at: url)
        } else {
            openWindow(value: filePath)
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
    @AppStorage(SettingsKeys.restoreOpenTabsOnLaunch) private var restoreOpenTabsOnLaunch = true

    var body: some Scene {
        editorScene
        Settings {
            SettingsView()
        }
    }

    private var editorScene: some Scene {
        WindowGroup("Graphics Script Editor", for: String.self) { filePath in
            ContentView(filePath: filePath)
        } defaultValue: {
            ""
        }
        .commands {
            EditorMenuCommands()
        }
    }
}
