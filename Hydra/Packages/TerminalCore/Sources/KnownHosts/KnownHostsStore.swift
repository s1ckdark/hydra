// vendored from iWorks/terminal @ 3b3545e — LOCALLY MODIFIED (see below), re-vendor requires re-applying these patches
import Foundation
import CryptoKit

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
            $0.keyType == entry.keyType && Self.hostMatches(pattern: $0.hostPattern, host: entry.hostPattern)
        }
        guard !sameHostAndType.isEmpty else { return .unknown }
        let queryToken = Self.keyToken(entry.publicKey)
        return sameHostAndType.contains { Self.keyToken($0.publicKey) == queryToken } ? .match : .mismatch
    }

    /// Does a stored known_hosts host field match the host we're looking up?
    ///
    /// The query `host` is always a plain single host string (e.g. an IP or
    /// hostname). Stored fields come in three shapes:
    ///   • plain single host          → exact compare
    ///   • comma list `a,b,c`         → membership (real OpenSSH multi-host lines)
    ///   • hashed `|1|<salt>|<hash>`  → HMAC-SHA1(salt, host) == hash
    ///
    /// LOCAL PATCH (I4): hashed-entry support. macOS OpenSSH defaults to
    /// `HashKnownHosts yes`, so a user who already trusts a host via the ssh CLI
    /// has it stored ONLY as a `|1|…` line. Without decoding these, the app's
    /// exact-string match never finds them and re-prompts TOFU for hosts the
    /// system already knows. We recompute the HMAC the same way OpenSSH does
    /// (HMAC-SHA1 keyed by the per-entry salt) and compare.
    static func hostMatches(pattern: String, host: String) -> Bool {
        if pattern.hasPrefix("|1|") {
            return hashedHostMatches(pattern: pattern, host: host)
        }
        if pattern.contains(",") {
            return pattern.split(separator: ",").contains { $0 == Substring(host) }
        }
        return pattern == host
    }

    /// `|1|<base64 salt>|<base64 HMAC-SHA1(salt, hostname)>` — recompute and compare.
    private static func hashedHostMatches(pattern: String, host: String) -> Bool {
        let comps = pattern.split(separator: "|", omittingEmptySubsequences: false)
        // "|1|salt|hash" → ["", "1", salt, hash]
        guard comps.count == 4, comps[1] == "1",
              let salt = Data(base64Encoded: String(comps[2])) else { return false }
        let expected = String(comps[3])
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.utf8),
                                                         using: SymmetricKey(data: salt))
        return Data(mac).base64EncodedString() == expected
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
