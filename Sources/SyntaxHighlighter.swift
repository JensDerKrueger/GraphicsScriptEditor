import AppKit

struct SyntaxThemeColors {
    let baseColor: NSColor
    let keywordColor: NSColor
    let numberColor: NSColor
    let variableColor: NSColor
    let commentColor: NSColor
    let errorUnderlineColor: NSColor
}

struct HighlightPlan {
    let textLength: Int
    let commentRanges: [NSRange]
    let numberRanges: [NSRange]
    let variableRanges: [NSRange]
    let keywordRanges: [NSRange]
    let diagnosticRanges: [NSRange]
}

final class SyntaxHighlighter {
    private struct DocumentLine {
        let text: String
        let range: NSRange
    }

    private struct VariableReference {
        let range: NSRange
        let name: String
    }

    private enum LineVariableEffect {
        case set(String)
        case unset(String)
        case repeatLoop(String?)
        case endRepeat
    }

    private struct CachedLineAnalysis {
        let text: String
        let commentRange: NSRange?
        let numberRanges: [NSRange]
        let variableReferences: [VariableReference]
        let keywordRange: NSRange?
        let variableEffect: LineVariableEffect?
    }

    private let maxDetailedLineLength = 512
    private let maxDetailedCommentLength = 256
    private let numberRegex = try? NSRegularExpression(pattern: "\\b-?\\d+(?:\\.\\d+)?\\b")
    private let variableRegex = try? NSRegularExpression(
        pattern: "(?<!\\$)\\$(?:\\{([A-Za-z_][A-Za-z0-9_]*)\\}|([A-Za-z_][A-Za-z0-9_]*))"
    )
    private let cacheLock = NSLock()
    private var cachedLineAnalysesByText: [String: CachedLineAnalysis] = [:]

    func makePlan(
        for text: String,
        commandNames: Set<String>,
        diagnostics: [Diagnostic]
    ) -> HighlightPlan {
        let fullText = text as NSString
        let fullRange = NSRange(location: 0, length: fullText.length)
        let documentLines = documentLines(in: fullText, range: fullRange)
        let lineAnalyses = cachedAnalyses(for: documentLines, commandNames: commandNames)
        let diagnosticLines = Set(diagnostics.map(\.line))

        var commentRanges: [NSRange] = []
        var numberRanges: [NSRange] = []
        var variableRanges: [NSRange] = []
        var keywordRanges: [NSRange] = []
        var diagnosticRanges: [NSRange] = []
        var definedVariables: Set<String> = []
        var loopCounterStack: [String?] = []

        for (index, line) in documentLines.enumerated() {
            let analysis = lineAnalyses[index]

            if let commentRange = analysis.commentRange {
                commentRanges.append(absoluteRange(from: commentRange, lineRange: line.range))
            }

            if let keywordRange = analysis.keywordRange {
                keywordRanges.append(absoluteRange(from: keywordRange, lineRange: line.range))
            }

            for numberRange in analysis.numberRanges {
                numberRanges.append(absoluteRange(from: numberRange, lineRange: line.range))
            }

            for variableReference in analysis.variableReferences where definedVariables.contains(variableReference.name) {
                variableRanges.append(absoluteRange(from: variableReference.range, lineRange: line.range))
            }

            applyVariableEffect(
                analysis.variableEffect,
                definedVariables: &definedVariables,
                loopCounterStack: &loopCounterStack
            )

            if diagnosticLines.contains(index + 1) {
                diagnosticRanges.append(line.range)
            }
        }

        return HighlightPlan(
            textLength: fullText.length,
            commentRanges: commentRanges,
            numberRanges: numberRanges,
            variableRanges: variableRanges,
            keywordRanges: keywordRanges,
            diagnosticRanges: diagnosticRanges
        )
    }

    func apply(
        plan: HighlightPlan,
        to textView: NSTextView,
        baseFont: NSFont,
        colors: SyntaxThemeColors
    ) {
        guard let textStorage = textView.textStorage else { return }

        let fullText = textView.string as NSString
        guard fullText.length == plan.textLength else { return }

        let fullRange = NSRange(location: 0, length: fullText.length)
        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: colors.baseColor
        ], range: fullRange)

        for range in plan.commentRanges {
            textStorage.addAttributes([
                .foregroundColor: colors.commentColor
            ], range: range)
        }

        for range in plan.numberRanges {
            textStorage.addAttributes([
                .foregroundColor: colors.numberColor
            ], range: range)
        }

        for range in plan.variableRanges {
            textStorage.addAttributes([
                .foregroundColor: colors.variableColor
            ], range: range)
        }

        for range in plan.keywordRanges {
            textStorage.addAttributes([
                .foregroundColor: colors.keywordColor
            ], range: range)
        }

        for range in plan.diagnosticRanges {
            textStorage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: colors.errorUnderlineColor
            ], range: range)
        }

        textStorage.endEditing()
    }

    private func documentLines(in text: NSString, range: NSRange) -> [DocumentLine] {
        var lines: [DocumentLine] = []
        text.enumerateSubstrings(in: range, options: [.byLines]) { line, lineRange, _, _ in
            lines.append(DocumentLine(text: line ?? "", range: lineRange))
        }
        return lines
    }

    private func cachedAnalyses(for documentLines: [DocumentLine], commandNames: Set<String>) -> [CachedLineAnalysis] {
        cacheLock.lock()
        let cachedAnalysesByText = cachedLineAnalysesByText
        cacheLock.unlock()

        var updatedCache = cachedAnalysesByText
        let resolvedAnalyses = documentLines.map { line in
            if let cachedAnalysis = cachedAnalysesByText[line.text] {
                return cachedAnalysis
            }

            let analysis = analyze(line, commandNames: commandNames)
            updatedCache[line.text] = analysis
            return analysis
        }

        cacheLock.lock()
        cachedLineAnalysesByText = updatedCache
        cacheLock.unlock()

        return resolvedAnalyses
    }

    private func analyze(_ line: DocumentLine, commandNames: Set<String>) -> CachedLineAnalysis {
        let lineNSString = line.text as NSString
        var codeRangeLength = line.range.length
        let commentRangeInLine = lineNSString.range(of: "#")
        var commentRange: NSRange?

        if commentRangeInLine.location != NSNotFound {
            codeRangeLength = commentRangeInLine.location
            commentRange = NSRange(location: commentRangeInLine.location, length: line.range.length - commentRangeInLine.location)
        }

        let keywordRange = leadingCommandRange(in: lineNSString, codeRangeLength: codeRangeLength)
        let codeText = codeRangeLength > 0
            ? lineNSString.substring(with: NSRange(location: 0, length: codeRangeLength))
            : ""
        let variableEffect = variableEffect(for: codeText)
        let commentLength = commentRange?.length ?? 0

        guard codeRangeLength <= maxDetailedLineLength,
              commentLength <= maxDetailedCommentLength else {
            return CachedLineAnalysis(
                text: line.text,
                commentRange: commentRange,
                numberRanges: [],
                variableReferences: [],
                keywordRange: keywordRange.flatMap { localRange in
                    let token = lineNSString.substring(with: localRange)
                    return commandNames.contains(token) ? localRange : nil
                },
                variableEffect: variableEffect
            )
        }

        let codeNSString = codeText as NSString
        var numberRanges: [NSRange] = []
        if let numberRegex = numberRegex {
            numberRanges = numberRegex.matches(
                in: codeText,
                range: NSRange(location: 0, length: codeNSString.length)
            ).map(\.range)
        }

        let variableReferences = variableReferences(in: codeText)
        let resolvedKeywordRange = keywordRange.flatMap { localRange in
            let token = lineNSString.substring(with: localRange)
            return commandNames.contains(token) ? localRange : nil
        }

        return CachedLineAnalysis(
            text: line.text,
            commentRange: commentRange,
            numberRanges: numberRanges,
            variableReferences: variableReferences,
            keywordRange: resolvedKeywordRange,
            variableEffect: variableEffect
        )
    }

    private func variableReferences(in text: String) -> [VariableReference] {
        guard let variableRegex else {
            return []
        }

        let nsText = text as NSString
        let matches = variableRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var references: [VariableReference] = []

        for match in matches {
            let bracedNameRange = match.range(at: 1)
            let bareNameRange = match.range(at: 2)
            let nameRange = bracedNameRange.location != NSNotFound ? bracedNameRange : bareNameRange
            guard nameRange.location != NSNotFound else {
                continue
            }

            references.append(
                VariableReference(
                    range: match.range,
                    name: nsText.substring(with: nameRange)
                )
            )
        }

        return references
    }

    private func leadingCommandRange(in line: NSString, codeRangeLength: Int) -> NSRange? {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var startIndex = 0
        while startIndex < codeRangeLength {
            if let scalar = UnicodeScalar(line.character(at: startIndex)),
               !whitespace.contains(scalar) {
                break
            }
            startIndex += 1
        }

        guard startIndex < codeRangeLength else {
            return nil
        }

        var endIndex = startIndex
        while endIndex < codeRangeLength {
            if let scalar = UnicodeScalar(line.character(at: endIndex)),
               whitespace.contains(scalar) {
                break
            }
            endIndex += 1
        }

        return NSRange(location: startIndex, length: endIndex - startIndex)
    }

    private func variableEffect(for codeText: String) -> LineVariableEffect? {
        let tokens = leadingTokens(in: codeText, limit: 4)
        guard let command = tokens.first else {
            return nil
        }

        switch command {
        case "set":
            guard tokens.count >= 2, let name = variableName(from: tokens[1], allowBare: true) else {
                return nil
            }
            return .set(name)
        case "unset":
            guard tokens.count == 2, let name = variableName(from: tokens[1], allowBare: true) else {
                return nil
            }
            return .unset(name)
        case "repeat":
            if tokens.count == 4, tokens[2] == "as",
               let name = variableName(from: tokens[3], allowBare: true) {
                return .repeatLoop(name)
            }
            return .repeatLoop(nil)
        case "endrepeat":
            return .endRepeat
        default:
            return nil
        }
    }

    private func applyVariableEffect(
        _ effect: LineVariableEffect?,
        definedVariables: inout Set<String>,
        loopCounterStack: inout [String?]
    ) {
        guard let effect else {
            return
        }

        switch effect {
        case .set(let name):
            definedVariables.insert(name)
        case .unset(let name):
            definedVariables.remove(name)
        case .repeatLoop(let name):
            loopCounterStack.append(name)
            if let name {
                definedVariables.insert(name)
            }
        case .endRepeat:
            if let loopCounter = loopCounterStack.popLast(), let loopCounter {
                definedVariables.remove(loopCounter)
            }
        }
    }

    private func absoluteRange(from localRange: NSRange, lineRange: NSRange) -> NSRange {
        NSRange(location: lineRange.location + localRange.location, length: localRange.length)
    }

    private func leadingTokens(in text: String, limit: Int) -> [String] {
        guard limit > 0 else {
            return []
        }

        var tokens: [String] = []
        var currentStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex, tokens.count < limit {
            if text[index].isWhitespace {
                if let tokenStart = currentStart {
                    tokens.append(String(text[tokenStart..<index]))
                    if tokens.count == limit {
                        break
                    }
                    currentStart = nil
                }
            } else if currentStart == nil {
                currentStart = index
            }

            index = text.index(after: index)
        }

        if let currentStart, tokens.count < limit {
            tokens.append(String(text[currentStart..<text.endIndex]))
        }

        return tokens
    }

    private func variableName(from token: String, allowBare: Bool) -> String? {
        if token.hasPrefix("${"), token.hasSuffix("}") {
            let start = token.index(token.startIndex, offsetBy: 2)
            let end = token.index(before: token.endIndex)
            let name = String(token[start..<end])
            return isValidVariableName(name) ? name : nil
        }

        if token.hasPrefix("$") {
            let name = String(token.dropFirst())
            return isValidVariableName(name) ? name : nil
        }

        guard allowBare, isValidVariableName(token) else {
            return nil
        }

        return token
    }

    private func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.first, isVariableStart(first) else {
            return false
        }
        return name.dropFirst().allSatisfy(isVariableBody)
    }

    private func isVariableStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isVariableBody(_ character: Character) -> Bool {
        isVariableStart(character) || character.isNumber
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
            return nil
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    var hexStringValue: String? {
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return nil
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
