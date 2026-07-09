// vendored from iWorks/terminal @ 3b3545e — LOCALLY MODIFIED (see below), re-vendor requires re-applying these patches
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

    // LOCAL PATCH (I3): match on (hostPattern, keyType) together, not hostPattern alone —
    // real known_hosts commonly hold multiple key TYPES per host, so only look at entries
    // that share BOTH the host and the presented key's type. Compare the base64 key token
    // only (comment-stripped) so real OpenSSH lines (which may carry a trailing comment)
    // still compare equal. No entry for that (host, keyType) pair → .unknown (→ TOFU),
    // never a false .mismatch just because the first stored entry is a different key type.
    public func check(_ entry: KnownHostsEntry) throws -> KnownHostsCheck {
        let entries = try readAll()
        let sameHostAndType = entries.filter {
            $0.hostPattern == entry.hostPattern && $0.keyType == entry.keyType
        }
        guard !sameHostAndType.isEmpty else { return .unknown }
        let queryToken = Self.keyToken(entry.publicKey)
        return sameHostAndType.contains { Self.keyToken($0.publicKey) == queryToken } ? .match : .mismatch
    }

    /// The base64 key material only, with any trailing "comment" text stripped.
    private static func keyToken(_ publicKey: String) -> Substring {
        publicKey.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? Substring(publicKey)
    }

    public func trust(_ entry: KnownHostsEntry) throws {
        let line = KnownHostsParser.format(entry) + "\n"
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            let endOffset = try handle.seekToEnd()
            // LOCAL PATCH (I2): if the file already has content but doesn't end in a
            // newline, prefix one before appending — otherwise our entry concatenates onto
            // the real known_hosts' last line, corrupting an entry OpenSSH also reads.
            if endOffset > 0 {
                try handle.seek(toOffset: endOffset - 1)
                let lastByte = handle.readData(ofLength: 1)
                try handle.seekToEnd()
                if lastByte != Data([0x0A]) {
                    try handle.write(contentsOf: Data([0x0A]))
                }
            }
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
