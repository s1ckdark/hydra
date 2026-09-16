import XCTest
import KnownHosts
@testable import HydraiOS

final class SSHKnownHostsStorageTests: XCTestCase {
    func testDefaultStorageIsInsideApplicationSupport() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(SSHKnownHostsStorage.defaultURL, base.appendingPathComponent("Hydra/SSH/known_hosts"))
    }

    func testRealAppContainerAllowsTrustWriteReadAndAppend() throws {
        // Shares the production directory, but never modifies real trust entries.
        let file = SSHKnownHostsStorage.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("qa-\(UUID().uuidString).known_hosts")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = KnownHostsStore(fileURL: file)
        let first = KnownHostsEntry(hostPattern: "fixture.invalid", keyType: "ssh-ed25519", publicKey: "AAAA")
        try store.trust(first)
        try store.trust(.init(hostPattern: "second.invalid", keyType: "ssh-ed25519", publicKey: "BBBB"))
        XCTAssertEqual(try store.check(first), .match)
        XCTAssertEqual(try KnownHostsStore(fileURL: file).check(first), .match)
    }
}
