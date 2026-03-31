import SwiftUI
import UniformTypeIdentifiers

struct GraphicsScriptDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [
            GraphicsScriptFileType.contentType,
            .plainText
        ]
    }

    var text: String

    init(text: String = EditorModel.defaultScriptText) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        return FileWrapper(regularFileWithContents: data)
    }
}
