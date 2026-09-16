import Foundation
import KnownHosts

/// Registration and the terminal must use the same durable trust file.
enum SSHKnownHostsStorage {
    static var defaultURL: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Hydra/SSH/known_hosts")
        #endif
    }

    static func makeStore(override: URL? = nil) -> KnownHostsStore {
        if let override { return KnownHostsStore(fileURL: override) }
        #if os(macOS)
        return KnownHostsStore(fileURL: defaultURL)
        #else
        return KnownHostsStore(fileURL: defaultURL,
            legacyFileURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/known_hosts"))
        #endif
    }
}
