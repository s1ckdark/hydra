// vendored from iWorks/terminal @ 3b3545e, do not edit here
import Foundation

public enum KnownHostsCheck: Equatable {
    case unknown    // host not in file
    case match      // host present, key matches
    case mismatch   // host present, different key
}

public final class KnownHostsStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func check(_ entry: KnownHostsEntry) throws -> KnownHostsCheck {
        let entries = try readAll()
        if let existing = entries.first(where: { $0.hostPattern == entry.hostPattern }) {
            return existing == entry ? .match : .mismatch
        }
        return .unknown
    }

    public func trust(_ entry: KnownHostsEntry) throws {
        let line = KnownHostsParser.format(entry) + "\n"
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try Data(line.utf8).write(to: fileURL)
        }
    }

    private func readAll() throws -> [KnownHostsEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let body = try String(contentsOf: fileURL, encoding: .utf8)
        return body.components(separatedBy: "\n").compactMap(KnownHostsParser.parseLine)
    }
}
