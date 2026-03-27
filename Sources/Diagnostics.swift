import Foundation

struct Diagnostic: Identifiable, Hashable {
    let id = UUID()
    let line: Int
    let message: String
    let code: CommandResultCode
}
