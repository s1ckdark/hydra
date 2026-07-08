import Foundation

/// A user-defined, named Python snippet run in the in-app console.
struct PySnippet: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var code: String
    var createdAt: Date = Date()
    var lastRunAt: Date?
    var lastExitCode: Int32?
}
