import SwiftUI
import AppKit

final class IndentingTextView: NSTextView {
    var onInsertNewline: (() -> Bool)?
    var onInsertTab: (() -> Bool)?
    var onInsertBacktab: (() -> Bool)?
    var onPaste: (() -> Bool)?

    override func insertNewline(_ sender: Any?) {
        if onInsertNewline?() == true {
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if onInsertTab?() == true {
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if onInsertBacktab?() == true {
            return
        }
        super.insertBacktab(sender)
    }

    override func paste(_ sender: Any?) {
        if onPaste?() == true {
            return
        }
        super.paste(sender)
    }
}

final class LineNumberView: NSView {
    weak var textView: NSTextView?
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            needsDisplay = true
        }
    }
    var lineStartLocations: [Int] = [0] {
        didSet {
            needsDisplay = true
        }
    }

    private let horizontalPadding: CGFloat = 8

    override var isFlipped: Bool {
        true
    }

    func updateFrameHeight(editorDocumentHeight: CGFloat, visibleHeight: CGFloat) {
        let targetHeight = max(editorDocumentHeight, visibleHeight)
        frame = NSRect(x: 0, y: 0, width: frame.width, height: targetHeight)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let text = textView.string as NSString
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let startLineIndex = lineIndex(for: characterRange.location)
        let endLocation = min(text.length, NSMaxRange(characterRange))

        for lineIndex in startLineIndex..<lineStartLocations.count {
            let lineStart = lineStartLocations[lineIndex]
            if lineStart > endLocation && lineIndex > startLineIndex {
                break
            }

            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let glyphRangeForLine = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRangeForLine, in: textContainer)
            let yPosition = lineRect.minY + textView.textContainerInset.height - visibleRect.minY
            let label = "\(lineIndex + 1)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            if yPosition + labelSize.height < bounds.minY {
                continue
            }
            if yPosition > bounds.maxY {
                break
            }
            let xPosition = bounds.width - horizontalPadding - labelSize.width
            label.draw(at: NSPoint(x: xPosition, y: yPosition), withAttributes: attributes)
        }

        NSColor.separatorColor.setStroke()
        let x = bounds.maxX - 0.5
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: x, y: bounds.minY))
        separator.line(to: NSPoint(x: x, y: bounds.maxY))
        separator.stroke()
    }

    private func lineIndex(for location: Int) -> Int {
        guard !lineStartLocations.isEmpty else {
            return 0
        }

        var low = 0
        var high = lineStartLocations.count - 1
        var result = 0

        while low <= high {
            let mid = (low + high) / 2
            if lineStartLocations[mid] <= location {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }
}

final class EditorContainerView: NSView {
    let lineNumberView = LineNumberView()
    let editorScrollView = NSScrollView()

    private let gutterWidth: CGFloat = 52
    private var lineNumbersVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let activeGutterWidth = lineNumbersVisible ? gutterWidth : 0
        lineNumberView.isHidden = !lineNumbersVisible
        lineNumberView.frame = NSRect(x: 0, y: 0, width: activeGutterWidth, height: bounds.height)
        editorScrollView.frame = NSRect(
            x: activeGutterWidth,
            y: 0,
            width: max(0, bounds.width - activeGutterWidth),
            height: bounds.height
        )
    }

    func updateGutter(font: NSFont) {
        lineNumberView.font = font
        lineNumberView.needsDisplay = true
    }

    func setLineNumbersVisible(_ isVisible: Bool) {
        lineNumbersVisible = isVisible
        needsLayout = true
        lineNumberView.needsDisplay = true
    }

    func updateLineNumbers(text: String) {
        lineNumberView.lineStartLocations = lineStartLocations(for: text)
    }

    func syncGutterScrollPosition() {
        lineNumberView.needsDisplay = true
    }

    private func configureViews() {
        wantsLayer = true
        layer?.masksToBounds = true

        lineNumberView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: 0)

        editorScrollView.hasVerticalScroller = true
        editorScrollView.hasHorizontalScroller = true
        editorScrollView.borderType = .bezelBorder
        editorScrollView.autohidesScrollers = true
        editorScrollView.drawsBackground = true
        editorScrollView.contentView.postsBoundsChangedNotifications = true

        addSubview(lineNumberView)
        addSubview(editorScrollView)
    }

    private func lineStartLocations(for text: String) -> [Int] {
        guard !text.isEmpty else {
            return [0]
        }

        let nsString = text as NSString
        var starts: [Int] = [0]
        var location = 0

        while location < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            if location < nsString.length {
                starts.append(location)
            }
        }

        if text.hasSuffix("\n") {
            starts.append(nsString.length)
        }

        return starts
    }
}

struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    let diagnostics: [Diagnostic]
    let commandNames: Set<String>
    let fontName: String
    let fontSize: CGFloat
    let showsLineNumbers: Bool
    let indentationUnit: String
    let baseColorHex: String
    let keywordColorHex: String
    let numberColorHex: String
    let variableColorHex: String
    let commentColorHex: String
    let errorUnderlineColorHex: String
    let onTextChange: (() -> Void)?
    let onSelectionChange: ((Int, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let containerView = EditorContainerView()
        let scrollView = containerView.editorScrollView

        let textView = IndentingTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = resolvedEditorFont
        textView.string = text
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.onInsertNewline = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else {
                return false
            }
            coordinator.insertIndentedNewline(in: textView)
            return true
        }
        textView.onInsertTab = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else {
                return false
            }
            coordinator.insertTab(in: textView)
            return true
        }
        textView.onInsertBacktab = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else {
                return false
            }
            coordinator.insertBacktab(in: textView)
            return true
        }
        textView.onPaste = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else {
                return false
            }
            return coordinator.paste(in: textView)
        }

        scrollView.documentView = textView
        containerView.lineNumberView.textView = textView
        containerView.setLineNumbersVisible(showsLineNumbers)
        containerView.updateLineNumbers(text: text)
        containerView.updateGutter(font: resolvedEditorFont)
        context.coordinator.textView = textView
        context.coordinator.containerView = containerView
        context.coordinator.startObservingScrollView(scrollView)
        context.coordinator.reportSelection(in: textView)
        context.coordinator.applyHighlighting(
            commandNames: commandNames,
            diagnostics: diagnostics,
            font: resolvedEditorFont,
            colors: resolvedThemeColors
        )

        return containerView
    }

    func updateNSView(_ nsView: EditorContainerView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if context.coordinator.isUpdating {
            return
        }

        textView.font = resolvedEditorFont
        nsView.setLineNumbersVisible(showsLineNumbers)
        nsView.updateGutter(font: resolvedEditorFont)
        nsView.needsLayout = true

        if textView.hasMarkedText() {
            return
        }

        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            nsView.updateLineNumbers(text: text)
            nsView.updateGutter(font: resolvedEditorFont)
            context.coordinator.scheduleHighlighting(
                commandNames: commandNames,
                diagnostics: diagnostics,
                font: resolvedEditorFont,
                colors: resolvedThemeColors
            )
            context.coordinator.isUpdating = false
        } else {
            context.coordinator.scheduleHighlighting(
                commandNames: commandNames,
                diagnostics: diagnostics,
                font: resolvedEditorFont,
                colors: resolvedThemeColors
            )
        }
    }

    private var resolvedEditorFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private var resolvedThemeColors: SyntaxThemeColors {
        SyntaxThemeColors(
            baseColor: NSColor(hexString: baseColorHex) ?? .textColor,
            keywordColor: NSColor(hexString: keywordColorHex) ?? .systemBlue,
            numberColor: NSColor(hexString: numberColorHex) ?? .systemOrange,
            variableColor: NSColor(hexString: variableColorHex) ?? .systemPurple,
            commentColor: NSColor(hexString: commentColorHex) ?? .systemGreen,
            errorUnderlineColor: NSColor(hexString: errorUnderlineColorHex) ?? .systemRed
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: EditorTextView
        var textView: NSTextView?
        weak var containerView: EditorContainerView?
        var isUpdating = false
        private let highlighter = SyntaxHighlighter()
        private var scrollObserver: NSObjectProtocol?
        private var lastReportedSelection: (line: Int, column: Int)?
        private var pendingHighlightWorkItem: DispatchWorkItem?
        private var highlightGeneration = 0

        init(_ parent: EditorTextView) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            pendingHighlightWorkItem?.cancel()
        }

        func startObservingScrollView(_ scrollView: NSScrollView) {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }

            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.containerView?.syncGutterScrollPosition()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            if isUpdating { return }
            if textView.hasMarkedText() { return }

            isUpdating = true
            parent.text = textView.string
            containerView?.updateLineNumbers(text: textView.string)
            containerView?.updateGutter(font: parent.resolvedEditorFont)
            scheduleHighlighting(
                commandNames: parent.commandNames,
                diagnostics: parent.diagnostics,
                font: parent.resolvedEditorFont,
                colors: parent.resolvedThemeColors
            )
            isUpdating = false

            parent.onTextChange?()
            reportSelection(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            reportSelection(in: textView)
        }

        func applyHighlighting(commandNames: Set<String>, diagnostics: [Diagnostic], font: NSFont, colors: SyntaxThemeColors) {
            guard let textView = textView else { return }
            let plan = highlighter.makePlan(
                for: textView.string,
                commandNames: commandNames,
                diagnostics: diagnostics
            )
            highlighter.apply(
                plan: plan,
                to: textView,
                baseFont: font,
                colors: colors
            )
        }

        func scheduleHighlighting(commandNames: Set<String>, diagnostics: [Diagnostic], font: NSFont, colors: SyntaxThemeColors) {
            pendingHighlightWorkItem?.cancel()
            guard let textView else { return }

            let textSnapshot = textView.string
            highlightGeneration += 1
            let generation = highlightGeneration
            let delay = textSnapshot.count > 8_000 ? 0.2 : 0.08

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }

                let plan = self.highlighter.makePlan(
                    for: textSnapshot,
                    commandNames: commandNames,
                    diagnostics: diagnostics
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.highlightGeneration == generation,
                          let textView = self.textView,
                          textView.string == textSnapshot else {
                        return
                    }

                    self.highlighter.apply(
                        plan: plan,
                        to: textView,
                        baseFont: font,
                        colors: colors
                    )
                }
            }

            pendingHighlightWorkItem = workItem
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func insertIndentedNewline(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else {
                textView.insertNewline(nil)
                return
            }

            var selectedRange = textView.selectedRange()
            let nsString = textStorage.string as NSString
            let lineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineText = nsString.substring(with: lineRange)
            let textBeforeCursor = nsString.substring(with: NSRange(location: lineRange.location, length: max(0, selectedRange.location - lineRange.location)))
            let leadingIndentation = Self.leadingWhitespace(in: lineText)
            let trimmedBeforeCursor = textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let commandBeforeCursor = Self.leadingCommand(in: trimmedBeforeCursor)
            let lineCommand = Self.leadingCommand(in: trimmedLine)
            let baseIndentationLevel = indentationLevel(before: lineRange.location, in: nsString)
            let expectedCurrentIndentation = indentationString(
                for: expectedIndentationLevel(for: lineCommand, baseLevel: baseIndentationLevel)
            )

            if shouldCorrectCurrentLineIndentation(for: lineCommand),
               leadingIndentation != expectedCurrentIndentation {
                let indentationRange = NSRange(location: lineRange.location, length: leadingIndentation.count)
                textView.insertText(expectedCurrentIndentation, replacementRange: indentationRange)
                selectedRange = textView.selectedRange()
            }

            let nextLineIndentation = indentationString(
                for: nextIndentationLevel(
                    for: commandBeforeCursor.isEmpty ? lineCommand : commandBeforeCursor,
                    baseLevel: baseIndentationLevel
                )
            )

            let insertion = "\n" + nextLineIndentation
            isUpdating = true
            textView.insertText(insertion, replacementRange: selectedRange)
            syncParentText(from: textView)
        }

        func insertTab(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else {
                textView.insertTab(nil)
                return
            }

            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0 else {
                isUpdating = true
                textView.insertText(parent.indentationUnit, replacementRange: selectedRange)
                syncParentText(from: textView)
                return
            }

            let nsString = textStorage.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let blockText = nsString.substring(with: lineRange)
            let indentedText = blockText.replacingOccurrences(
                of: "(?m)^",
                with: NSRegularExpression.escapedPattern(for: parent.indentationUnit),
                options: .regularExpression
            )

            isUpdating = true
            textView.insertText(indentedText, replacementRange: lineRange)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (indentedText as NSString).length))
            syncParentText(from: textView)
        }

        func insertBacktab(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else {
                textView.insertBacktab(nil)
                return
            }

            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0 else {
                let currentSelection = textView.selectedRange()
                guard currentSelection.location > 0 else {
                    return
                }

                let nsString = textStorage.string as NSString
                let lineRange = nsString.lineRange(for: currentSelection)
                let lineText = nsString.substring(with: lineRange)
                let leadingWhitespace = Self.leadingWhitespace(in: lineText)
                let removalLength = removableIndentLength(for: leadingWhitespace)
                guard removalLength > 0 else {
                    return
                }

                let removalRange = NSRange(location: lineRange.location, length: removalLength)
                isUpdating = true
                textView.insertText("", replacementRange: removalRange)
                let updatedLocation = max(lineRange.location, currentSelection.location - removalLength)
                textView.setSelectedRange(NSRange(location: updatedLocation, length: 0))
                syncParentText(from: textView)
                return
            }

            let nsString = textStorage.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let blockText = nsString.substring(with: lineRange)
            let lines = blockText.components(separatedBy: "\n")
            let adjustedLines = lines.map { line in
                let removalLength = removableIndentLength(for: line)
                guard removalLength > 0 else {
                    return line
                }
                return String(line.dropFirst(removalLength))
            }
            let dedentedText = adjustedLines.joined(separator: "\n")

            isUpdating = true
            textView.insertText(dedentedText, replacementRange: lineRange)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (dedentedText as NSString).length))
            syncParentText(from: textView)
        }

        func paste(in textView: NSTextView) -> Bool {
            guard let pasteboardString = NSPasteboard.general.string(forType: .string),
                  pasteboardString.contains("\n"),
                  let textStorage = textView.textStorage else {
                return false
            }

            let selectedRange = textView.selectedRange()
            let nsString = textStorage.string as NSString
            let lineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let textBeforeCursor = nsString.substring(
                with: NSRange(
                    location: lineRange.location,
                    length: max(0, selectedRange.location - lineRange.location)
                )
            )
            let onlyWhitespaceBeforeCursor = textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let baseIndentationLevel = indentationLevel(before: selectedRange.location, in: nsString)
            let normalizedText = pasteboardString.replacingOccurrences(of: "\r\n", with: "\n")
            let lines = normalizedText.components(separatedBy: "\n")
            guard lines.count > 1 else {
                return false
            }

            isUpdating = true
            var insertionRange = selectedRange
            var runningIndentationLevel = max(0, baseIndentationLevel)

            for (index, line) in lines.enumerated() {
                let trimmedLine = line.replacingOccurrences(
                    of: #"^[ \t]+"#,
                    with: "",
                    options: .regularExpression
                )

                let insertion: String
                if index == 0 {
                    if onlyWhitespaceBeforeCursor {
                        insertionRange = NSRange(
                            location: lineRange.location,
                            length: selectedRange.length + max(0, selectedRange.location - lineRange.location)
                        )
                    }

                    if trimmedLine.isEmpty {
                        insertion = onlyWhitespaceBeforeCursor ? textBeforeCursor : line
                    } else {
                        let firstLineContent = onlyWhitespaceBeforeCursor ? trimmedLine : line
                        let command = Self.commandForIndentation(in: firstLineContent)

                        if onlyWhitespaceBeforeCursor {
                            let indentationLevelForLine = expectedIndentationLevel(
                                for: command,
                                baseLevel: runningIndentationLevel
                            )
                            insertion = indentationString(for: indentationLevelForLine) + trimmedLine
                        } else {
                            insertion = line
                        }

                        runningIndentationLevel = nextIndentationLevel(
                            for: command,
                            baseLevel: runningIndentationLevel
                        )
                    }
                } else if trimmedLine.isEmpty {
                    insertion = "\n"
                } else {
                    let command = Self.commandForIndentation(in: trimmedLine)
                    let indentationLevelForLine = expectedIndentationLevel(
                        for: command,
                        baseLevel: runningIndentationLevel
                    )
                    insertion = "\n" + indentationString(for: indentationLevelForLine) + trimmedLine
                    runningIndentationLevel = nextIndentationLevel(
                        for: command,
                        baseLevel: runningIndentationLevel
                    )
                }

                textView.insertText(insertion, replacementRange: insertionRange)
                insertionRange = NSRange(
                    location: insertionRange.location + (insertion as NSString).length,
                    length: 0
                )
            }

            syncParentText(from: textView)
            return true
        }

        private static func leadingWhitespace(in line: String) -> String {
            String(line.prefix { $0 == " " || $0 == "\t" })
        }

        private static func leadingCommand(in line: String) -> String {
            line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        }

        private func shouldCorrectCurrentLineIndentation(for command: String) -> Bool {
            DSLCommandSet.blockClosingCommands.contains(command)
        }

        private func expectedIndentationLevel(for command: String, baseLevel: Int) -> Int {
            if DSLCommandSet.blockClosingCommands.contains(command) {
                return max(0, baseLevel - 1)
            }
            return max(0, baseLevel)
        }

        private func nextIndentationLevel(for command: String, baseLevel: Int) -> Int {
            if command == "else" {
                return max(0, baseLevel)
            }
            if DSLCommandSet.blockClosingCommands.contains(command) {
                return max(0, baseLevel - 1)
            }
            if DSLCommandSet.blockOpeningCommands.contains(command) {
                return max(0, baseLevel + 1)
            }
            return max(0, baseLevel)
        }

        private func indentationString(for level: Int) -> String {
            String(repeating: parent.indentationUnit, count: max(0, level))
        }

        private func indentationLevel(before location: Int, in text: NSString) -> Int {
            guard location > 0 else {
                return 0
            }

            let prefix = text.substring(with: NSRange(location: 0, length: location))
            var level = 0

            prefix.enumerateLines { line, _ in
                let command = Self.commandForIndentation(in: line)
                switch command {
                case "repeat", "if":
                    level += 1
                case "endrepeat", "endif":
                    level = max(0, level - 1)
                case "else":
                    break
                default:
                    break
                }
            }

            return level
        }

        private static func commandForIndentation(in line: String) -> String {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return leadingCommand(in: trimmed)
        }

        private func removableIndentLength(for line: String) -> Int {
            if line.hasPrefix(parent.indentationUnit) {
                return parent.indentationUnit.count
            }

            if line.hasPrefix("\t") {
                return 1
            }

            let leadingSpaces = line.prefix { $0 == " " }.count
            return min(leadingSpaces, max(1, parent.indentationUnit.count))
        }

        private func syncParentText(from textView: NSTextView) {
            parent.text = textView.string
            containerView?.updateLineNumbers(text: textView.string)
            containerView?.updateGutter(font: parent.resolvedEditorFont)
            scheduleHighlighting(
                commandNames: parent.commandNames,
                diagnostics: parent.diagnostics,
                font: parent.resolvedEditorFont,
                colors: parent.resolvedThemeColors
            )
            isUpdating = false
            parent.onTextChange?()
            reportSelection(in: textView)
        }

        func reportSelection(in textView: NSTextView) {
            let selectedLocation = textView.selectedRange().location
            let nsString = textView.string as NSString
            let clampedLocation = min(selectedLocation, nsString.length)
            var line = 1
            var column = 1

            if clampedLocation > 0 {
                let prefixRange = NSRange(location: 0, length: clampedLocation)
                let prefix = nsString.substring(with: prefixRange)
                let lines = prefix.components(separatedBy: "\n")
                line = lines.count
                column = (lines.last?.count ?? 0) + 1
            }

            let selection = (line: line, column: column)
            if let lastReportedSelection, lastReportedSelection == selection {
                return
            }

            lastReportedSelection = selection
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let lastReportedSelection = self.lastReportedSelection,
                      lastReportedSelection == selection else {
                    return
                }
                self.parent.onSelectionChange?(selection.line, selection.column)
            }
        }
    }
}
