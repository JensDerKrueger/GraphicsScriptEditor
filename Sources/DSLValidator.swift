import Foundation

final class DSLValidator {
    func validate(_ script: String) -> [Diagnostic] {
        let interpreter = CommandInterpreter()
        DSLCommandSet.registerAll(in: interpreter)

        let loadResult = interpreter.loadFromString(script)
        if loadResult != .success {
            return [diagnostic(from: loadResult, line: interpreter.lastErrorLine ?? 1)]
        }

        while true {
            let runResult = interpreter.runBatch(validateOnly: true)
            switch runResult {
            case .success:
                continue
            case .finished:
                return []
            default:
                return [diagnostic(from: runResult, line: interpreter.lastErrorLine ?? 1)]
            }
        }
    }

    private func diagnostic(from code: CommandResultCode, line: Int) -> Diagnostic {
        let message = code.description
        return Diagnostic(line: max(1, line), message: message, code: code)
    }
}
