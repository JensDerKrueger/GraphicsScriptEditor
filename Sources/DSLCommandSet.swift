import Foundation

struct DSLCommandSet {
    private struct BlockCommandDefinition {
        let openingCommands: Set<String>
        let closingCommands: Set<String>
    }

    struct CommandDefinition {
        let name: String
        let signatures: [[ArgType]]
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
        CommandDefinition(name: "logGLInfo", signatures: [[.bool]]),
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
                interpreter.registerCommand(def.name, signature)
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

    struct ParseResult {
        let definitions: [DSLCommandSet.CommandDefinition]
        let issues: [ParseIssue]
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
                issues: [ParseIssue(line: 1, message: "Could not read command definitions: \(error.localizedDescription)")]
            )
        }
    }

    static func parse(_ text: String) -> ParseResult {
        var definitionsByName: [String: [[ArgType]]] = [:]
        var order: [String] = []
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
                if definitionsByName[parsed.name] == nil {
                    definitionsByName[parsed.name] = []
                    order.append(parsed.name)
                }
                definitionsByName[parsed.name]?.append(parsed.signature)
            case .failure(let error):
                issues.append(ParseIssue(line: lineNumber, message: error.message))
            }
        }

        let definitions = order.compactMap { name -> DSLCommandSet.CommandDefinition? in
            guard let signatures = definitionsByName[name] else {
                return nil
            }
            return DSLCommandSet.CommandDefinition(name: name, signatures: signatures)
        }

        return ParseResult(definitions: definitions, issues: issues)
    }

    private static func stripComment(from line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else {
            return line
        }
        return String(line[..<hashIndex])
    }

    private static func parseDefinition(_ line: String) -> Result<(name: String, signature: [ArgType]), LineParseError> {
        guard let openParen = line.firstIndex(of: "(") else {
            return parseWhitespaceDefinition(line)
        }

        guard line.hasSuffix(")") else {
            return .failure(LineParseError(message: "Expected closing ')' in command definition"))
        }

        let name = line[..<openParen].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCommandName(name) else {
            return .failure(LineParseError(message: "Invalid command name"))
        }

        let argsStart = line.index(after: openParen)
        let argsEnd = line.index(before: line.endIndex)
        let args = String(line[argsStart..<argsEnd])

        return parseSignature(args).map { (name, $0) }
    }

    private static func parseWhitespaceDefinition(_ line: String) -> Result<(name: String, signature: [ArgType]), LineParseError> {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = parts.first, isValidCommandName(name) else {
            return .failure(LineParseError(message: "Invalid command name"))
        }

        guard parts.count > 1 else {
            return .success((name, []))
        }

        let args = parts.dropFirst().joined(separator: ",")
        return parseSignature(args).map { (name, $0) }
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
                return .failure(LineParseError(message: "Empty argument type"))
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
            return .failure(LineParseError(message: "restString must be the final argument type"))
        }

        return .success(signature)
    }

    private static func parseArgumentToken(_ token: String) -> Result<[ArgType], LineParseError> {
        let parts = token
            .split(separator: "*", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard parts.count <= 2 else {
            return .failure(LineParseError(message: "Invalid repeated argument syntax"))
        }

        guard let type = argType(named: parts[0]) else {
            return .failure(LineParseError(message: "Unknown argument type '\(parts[0])'"))
        }

        if parts.count == 1 {
            return .success([type])
        }

        guard type != .restString else {
            return .failure(LineParseError(message: "restString cannot be repeated"))
        }

        guard let repeatCount = Int(parts[1]), repeatCount > 0 else {
            return .failure(LineParseError(message: "Repeated argument count must be a positive integer"))
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
