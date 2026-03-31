import Foundation

struct DSLCommandSet {
    private struct BlockCommandDefinition {
        let openingCommands: Set<String>
        let closingCommands: Set<String>
    }

    private struct CommandDefinition {
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
        CommandDefinition(name: "prefilter", signatures: [[]]),

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
        CommandDefinition(name: "quit", signatures: [[]]),

        CommandDefinition(name: "constantSampleCount", signatures: [[.bool]]),
        CommandDefinition(name: "setrate", signatures: [[.float]]),
        CommandDefinition(name: "setsubdiv", signatures: [[.uint32]]),
        CommandDefinition(name: "setuseortho", signatures: [[.bool]]),
        CommandDefinition(name: "setusennfilter", signatures: [[.bool]]),
        CommandDefinition(name: "setmethod", signatures: [[.uint32]]),
        CommandDefinition(name: "setvolume", signatures: [[.uint32]]),
        CommandDefinition(name: "settffile", signatures: [[.string]]),
        CommandDefinition(name: "settfcode", signatures: [[.string]]),
        CommandDefinition(name: "settfparams", signatures: [[.bool, .float, .float]]),
        CommandDefinition(name: "resetrotation", signatures: [[]]),
        CommandDefinition(name: "setLevel", signatures: [[.uint32]]),
        CommandDefinition(name: "setrotation", signatures: [Array(repeating: .float, count: 16)]),
        CommandDefinition(name: "addrotationx", signatures: [[.float]]),
        CommandDefinition(name: "addrotationy", signatures: [[.float]]),
        CommandDefinition(name: "addrotationz", signatures: [[.float]]),
        CommandDefinition(name: "settranslation", signatures: [[.float, .float, .float]]),
        CommandDefinition(name: "settransformparams", signatures: [[.string]]),
        CommandDefinition(name: "setalphathreshold", signatures: [[.float]])
    ]

    private static let blockCommands = BlockCommandDefinition(
        openingCommands: ["repeat", "if", "else"],
        closingCommands: ["endrepeat", "endif", "else"]
    )

    static func registerAll(in interpreter: CommandInterpreter) {
        for def in definitions {
            for signature in def.signatures {
                interpreter.registerCommand(def.name, signature)
            }
        }
    }

    static var commandNames: Set<String> {
        var names = builtInCommands
        for def in definitions {
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
