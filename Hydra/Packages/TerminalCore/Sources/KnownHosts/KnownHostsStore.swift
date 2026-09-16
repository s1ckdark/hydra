// vendored from iWorks/terminal @ 3b3545e — LOCALLY MODIFIED (see below), re-vendor requires re-applying these patches
import Foundation
import CryptoKit

public enum KnownHostsCheck: Equatable {
    case unknown    // host not in file
    case match      // host present, key matches
    case mismatch   // host present, different key
}

public final class KnownHostsStore {
    private static let accessLock = NSLock()
    private let fileURL: URL
    private let legacyFileURL: URL?

    public init(fileURL: URL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
    }

    // LOCAL PATCH (I3): match on (hostPattern, keyType) together, not hostPattern alone —
    // real known_hosts commonly hold multiple key TYPES per host, so only look at entries
    // that share BOTH the host and the presented key's type. Compare the base64 key token
    // only (comment-stripped) so real OpenSSH lines (which may carry a trailing comment)
    // still compare equal. No entry for that (host, keyType) pair → .unknown (→ TOFU),
    // never a false .mismatch just because the first stored entry is a different key type.
    public func check(_ entry: KnownHostsEntry) throws -> KnownHostsCheck {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
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
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        // Preserve any prior pins before writing to a newly selected location.
        // Read errors must never be treated as an empty trust store.
        _ = try contents()
        try createParent()
        let line = KnownHostsParser.format(entry) + "\n"
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Reading the final byte requires a read/write descriptor.
            // forWritingTo + readData raises an Objective-C exception.
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            let endOffset = try handle.seekToEnd()
            // LOCAL PATCH (I2): if the file already has content but doesn't end in a
            // newline, prefix one before appending — otherwise our entry concatenates onto
            // the real known_hosts' last line, corrupting an entry OpenSSH also reads.
            if endOffset > 0 {
                try handle.seek(toOffset: endOffset - 1)
                let lastByte = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if lastByte != Data([0x0A]) {
                    try handle.write(contentsOf: Data([0x0A]))
                }
            }
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private func readAll() throws -> [KnownHostsEntry] {
        guard let data = try contents() else { return [] }
        guard let body = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return body.components(separatedBy: "\n").compactMap(KnownHostsParser.parseLine)
    }

    private func createParent() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The new file is authoritative after a successful atomic migration. The
    /// old file is retained for recovery, never merged back over later changes.
    /// Calls are serialized within the app so two store instances cannot race
    /// migration against the first newly trusted host.
    private func contents() throws -> Data? {
        if let current = try Self.readIfPresent(fileURL) { return current }
        guard let legacyFileURL, legacyFileURL != fileURL,
              let legacy = try Self.readIfPresent(legacyFileURL) else { return nil }
        try createParent()
        try legacy.write(to: fileURL, options: .atomic)
        return legacy
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let error = error as NSError
            // Only a genuinely absent file is a fresh trust store. Permission,
            // protection, invalid encoding and I/O errors remain failures.
            if error.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            if error.domain == NSPOSIXErrorDomain, error.code == 2 { return nil }
            throw error
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return data
    }
}
