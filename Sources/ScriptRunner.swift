import Foundation

enum ScriptRunnerError: LocalizedError {
    case runnerPathMissing
    case runnerNotExecutable(String)
    case launchFailed(String)
    case runnerExited(String)

    var errorDescription: String? {
        switch self {
        case .runnerPathMissing:
            return "Runner program path is not set. Open Settings and choose a program."
        case .runnerNotExecutable(let path):
            return "Runner program is not executable: \(path)"
        case .launchFailed(let description):
            return "Failed to launch runner: \(description)"
        case .runnerExited(let message):
            return message
        }
    }
}

struct ScriptRunner {
    static func run(
        programPath: String,
        runnerURL: URL?,
        scriptURL: URL
    ) -> Result<String, ScriptRunnerError> {
        guard !programPath.isEmpty else {
            return .failure(.runnerPathMissing)
        }

        let programURL = runnerURL ?? URL(fileURLWithPath: programPath)
        guard FileManager.default.isExecutableFile(atPath: programURL.path) else {
            return .failure(.runnerNotExecutable(programURL.path))
        }

        let process = Process()
        process.executableURL = programURL
        process.currentDirectoryURL = programURL.deletingLastPathComponent()
        process.arguments = ["--script", scriptURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let combined = ([output, errorOutput].filter { !$0.isEmpty }).joined(separator: "\n")
            let message = combined.isEmpty ? "Runner exited with code \(process.terminationStatus)." : combined
            return .failure(.runnerExited(message))
        }

        let combined = ([output, errorOutput].filter { !$0.isEmpty }).joined(separator: "\n")
        return .success(combined)
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
