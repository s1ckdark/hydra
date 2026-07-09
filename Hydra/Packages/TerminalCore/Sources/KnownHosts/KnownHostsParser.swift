// vendored from iWorks/terminal @ 3b3545e, do not edit here
import Foundation

public struct KnownHostsEntry: Equatable, Hashable {
    public let hostPattern: String
    public let keyType: String
    public let publicKey: String   // base64, no comment
    public init(hostPattern: String, keyType: String, publicKey: String) {
        self.hostPattern = hostPattern
        self.keyType = keyType
        self.publicKey = publicKey
    }
}

public enum KnownHostsParser {

    public static func parseLine(_ line: String) -> KnownHostsEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 2,
                                  omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        return KnownHostsEntry(
            hostPattern: String(parts[0]),
            keyType:     String(parts[1]),
            publicKey:   String(parts[2])
        )
    }

    public static func format(_ entry: KnownHostsEntry) -> String {
        "\(entry.hostPattern) \(entry.keyType) \(entry.publicKey)"
    }
}
