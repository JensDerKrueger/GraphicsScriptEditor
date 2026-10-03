import Foundation

struct DSLCommandSet {
    private struct BlockCommandDefinition {
        let openingCommands: Set<String>
        let closingCommands: Set<String>
    }

    struct CommandDefinition {
        let name: String
        let signatures: [[ArgType]]
        let returnType: ArgType?

        init(name: String, signatures: [[ArgType]], returnType: ArgType? = nil) {
            self.name = name
            self.signatures = signatures
            self.returnType = returnType
        }
    }

    static let builtInCommands: Set<String> = [
        "noop",
        "set",
        "unset",
        "repeat",
        "endrepeat",
        "if",
        "as",
        "else",
        "endif"
    ]

    private static let definitions: [CommandDefinition] = [
        CommandDefinition(name: "reset", signatures: [[]]),
        CommandDefinition(name: "setinteraction", signatures: [[.bool]]),
        CommandDefinition(name: "setbackground", signatures: [[.float, .float, .float, .float]]),
        CommandDefinition(name: "resize", signatures: [[.int, .int]]),
        CommandDefinition(name: "screenshot", signatures: [[], [.string]]),
        CommandDefinition(name: "setfpswindow", signatures: [[.float]]),
        CommandDefinition(name: "clearlog", signatures: [[]]),
        CommandDefinition(name: "logfile", signatures: [[.string]]),
        CommandDefinition(name: "logtime", signatures: [[]]),
        CommandDefinition(name: "logfps", signatures: [[]]),
        CommandDefinition(name: "logGPUInfo", signatures: [[], [.bool]]),
        CommandDefinition(name: "log", signatures: [[.restString]]),
        CommandDefinition(name: "setdir", signatures: [[.string]]),
        CommandDefinition(name: "quit", signatures: [[]])
    ]

    private static let blockCommands = BlockCommandDefinition(
        openingCommands: ["repeat", "if", "else"],
        closingCommands: ["endrepeat", "endif", "else"]
    )

    static func registerAll(in interpreter: CommandInterpreter,
                            extraDefinitions: [CommandDefinition] = []) {
        for def in definitions + extraDefinitions {
            for signature in def.signatures {
                if let returnType = def.returnType {
                    interpreter.registerValueFunction(def.name, signature, returning: returnType)
                } else {
                    interpreter.registerCommand(def.name, signature)
                }
            }
        }
    }

    static func commandNames(extraDefinitions: [CommandDefinition] = []) -> Set<String> {
        var names = builtInCommands
        for def in definitions + extraDefinitions {
            names.insert(def.name)
        }
        return names
    }

    static func valueFunctionNames(extraDefinitions: [CommandDefinition] = []) -> Set<String> {
        Set(extraDefinitions.compactMap { definition in
            definition.returnType == nil ? nil : definition.name
        })
    }

    static var blockOpeningCommands: Set<String> {
        blockCommands.openingCommands
    }

    static var blockClosingCommands: Set<String> {
        blockCommands.closingCommands
    }
}

struct CommandDefinitionFile {
    struct ParseIssue {
        let line: Int
        let message: String
    }

    private struct LineParseError: Error {
        let message: String
    }

    private struct ParsedDefinition {
        let name: String
        let signature: [ArgType]
        let returnType: ArgType?
    }

    private struct DefinitionKey: Hashable {
        let name: String
        let returnType: ArgType?
    }

    struct ParseResult {
        let definitions: [DSLCommandSet.CommandDefinition]
        let issues: [ParseIssue]
        let sourceReadFailed: Bool
    }

    static let filenameExtension = "gsccommands"

    static func load(from url: URL) -> ParseResult {
        do {
            let content = try SecurityScopedAccess.withAccess(to: url) {
                try String(contentsOf: url, encoding: .utf8)
            }
            return parse(content)
        } catch {
            return ParseResult(
                definitions: [],
                issues: [
                    ParseIssue(
                        line: 1,
                        message: String(format: String(localized: "Could not read command definitions: %@"), error.localizedDescription)
                    )
                ],
                sourceReadFailed: true
            )
        }
    }

    static func parse(_ text: String) -> ParseResult {
        var definitionsByKey: [DefinitionKey: [[ArgType]]] = [:]
        var order: [DefinitionKey] = []
        var issues: [ParseIssue] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = stripComment(from: rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty else {
                continue
            }

            switch parseDefinition(line) {
            case .success(let parsed):
                let key = DefinitionKey(name: parsed.name, returnType: parsed.returnType)
                if definitionsByKey[key] == nil {
                    definitionsByKey[key] = []
                    order.append(key)
                }
                definitionsByKey[key]?.append(parsed.signature)
            case .failure(let error):
                issues.append(ParseIssue(line: lineNumber, message: error.message))
            }
        }

        let definitions = order.compactMap { key -> DSLCommandSet.CommandDefinition? in
            guard let signatures = definitionsByKey[key] else {
                return nil
            }
            return DSLCommandSet.CommandDefinition(
                name: key.name,
                signatures: signatures,
                returnType: key.returnType
            )
        }

        return ParseResult(definitions: definitions, issues: issues, sourceReadFailed: false)
    }

    private static func stripComment(from line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else {
            return line
        }
        return String(line[..<hashIndex])
    }

    private static func parseDefinition(_ line: String) -> Result<ParsedDefinition, LineParseError> {
        let returnParts = line.components(separatedBy: "->")
        guard returnParts.count <= 2 else {
            return .failure(LineParseError(message: String(localized: "Invalid return type syntax")))
        }

        let declaration = returnParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let returnTypeResult = parseReturnType(returnParts.count == 2 ? returnParts[1] : nil)
        let returnType: ArgType?
        switch returnTypeResult {
        case .success(let parsedReturnType):
            returnType = parsedReturnType
        case .failure(let error):
            return .failure(error)
        }

        guard let openParen = declaration.firstIndex(of: "(") else {
            return parseWhitespaceDefinition(declaration, returnType: returnType)
        }

        guard declaration.hasSuffix(")") else {
            return .failure(LineParseError(message: String(localized: "Expected closing ')' in command definition")))
        }

        let name = declaration[..<openParen].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCommandName(name) else {
            return .failure(LineParseError(message: String(localized: "Invalid command name")))
        }

        let argsStart = declaration.index(after: openParen)
        let argsEnd = declaration.index(before: declaration.endIndex)
        let args = String(declaration[argsStart..<argsEnd])

        return parseSignature(args).map {
            ParsedDefinition(name: name, signature: $0, returnType: returnType)
        }
    }

    private static func parseWhitespaceDefinition(_ line: String,
                                                  returnType: ArgType?) -> Result<ParsedDefinition, LineParseError> {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = parts.first, isValidCommandName(name) else {
            return .failure(LineParseError(message: String(localized: "Invalid command name")))
        }

        guard parts.count > 1 else {
            return .success(ParsedDefinition(name: name, signature: [], returnType: returnType))
        }

        let args = parts.dropFirst().joined(separator: ",")
        return parseSignature(args).map {
            ParsedDefinition(name: name, signature: $0, returnType: returnType)
        }
    }

    private static func parseReturnType(_ rawReturnType: String?) -> Result<ArgType?, LineParseError> {
        guard let rawReturnType else {
            return .success(nil)
        }

        let name = rawReturnType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .failure(LineParseError(message: String(localized: "Expected return type after '->'")))
        }

        guard let returnType = argType(named: name), returnType != .restString else {
            return .failure(
                LineParseError(
                    message: String(format: String(localized: "Unknown return type '%@'"), name)
                )
            )
        }

        return .success(returnType)
    }

    private static func parseSignature(_ text: String) -> Result<[ArgType], LineParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success([])
        }

        var signature: [ArgType] = []
        let rawArguments = trimmed.split(separator: ",", omittingEmptySubsequences: false)

        for rawArgument in rawArguments {
            let token = rawArgument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return .failure(LineParseError(message: String(localized: "Empty argument type")))
            }

            switch parseArgumentToken(token) {
            case .success(let types):
                signature.append(contentsOf: types)
            case .failure(let error):
                return .failure(error)
            }
        }

        if let restStringIndex = signature.firstIndex(of: .restString),
           restStringIndex != signature.index(before: signature.endIndex) {
            return .failure(LineParseError(message: String(localized: "restString must be the final argument type")))
        }

        return .success(signature)
    }

    private static func parseArgumentToken(_ token: String) -> Result<[ArgType], LineParseError> {
        let parts = token
            .split(separator: "*", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard parts.count <= 2 else {
            return .failure(LineParseError(message: String(localized: "Invalid repeated argument syntax")))
        }

        guard let type = argType(named: parts[0]) else {
            return .failure(LineParseError(message: String(format: String(localized: "Unknown argument type '%@'"), String(parts[0]))))
        }

        if parts.count == 1 {
            return .success([type])
        }

        guard type != .restString else {
            return .failure(LineParseError(message: String(localized: "restString cannot be repeated")))
        }

        guard let repeatCount = Int(parts[1]), repeatCount > 0 else {
            return .failure(LineParseError(message: String(localized: "Repeated argument count must be a positive integer")))
        }

        return .success(Array(repeating: type, count: repeatCount))
    }

    private static func argType(named name: String) -> ArgType? {
        switch name.lowercased() {
        case "int":
            return .int
        case "int64":
            return .int64
        case "uint32":
            return .uint32
        case "bool":
            return .bool
        case "float":
            return .float
        case "double":
            return .double
        case "string":
            return .string
        case "reststring", "rest-string", "rest_string":
            return .restString
        default:
            return nil
        }
    }

    private static func isValidCommandName(_ name: String) -> Bool {
        guard !name.isEmpty else {
            return false
        }

        return !name.contains { character in
            character.isWhitespace || character == "(" || character == ")" || character == "#"
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
