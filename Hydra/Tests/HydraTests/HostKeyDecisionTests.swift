#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

final class HostKeyDecisionTests: XCTestCase {
    private func tempStore() -> (KnownHostsStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("khd-\(UUID().uuidString)")
        return (KnownHostsStore(fileURL: url), url)
    }
    private func fp(_ pub: String) -> HostKeyFingerprint {
        HostKeyFingerprint(keyType: "ssh-ed25519", publicKeyBase64: pub, sha256Hex: "ab12")
    }

    func testUnknownHostNeedsTrust() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: fp("K1"), store: store),
                       .needsTrust(sha256: "ab12"))
    }

    func testTrustedHostProceeds() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.trust(HostKeyGate.entry(host: "1.1.1.1", fingerprint: fp("K1")))
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: fp("K1"), store: store), .proceed)
    }

    func testChangedKeyBlocked() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.trust(HostKeyGate.entry(host: "1.1.1.1", fingerprint: fp("K1")))
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: fp("K2"), store: store), .blocked)
    }

    func testNilFingerprintBlocked() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: nil, store: store), .blocked)
    }

    // Regression: macOS OpenSSH defaults to HashKnownHosts, so already-trusted
    // hosts live only as `|1|salt|hash` lines. The store must match those (via
    // HMAC-SHA1) rather than re-prompting TOFU. Fixture line below was produced
    // by `ssh-keygen -H` (independent oracle) for host 1.2.3.4 + this ed25519 key.
    private static let hashedFixture =
        "|1|eALMrnTseIYOdJLsp4UtMA71IBY=|boveoMSUsofP4OB9BrZKbXoA9NM= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL1uvigprcEzMP6Iq598bdsA10rztIukB5b5Nbcq1b1B"
    private static let hashedFixturePub = "AAAAC3NzaC1lZDI1NTE5AAAAIL1uvigprcEzMP6Iq598bdsA10rztIukB5b5Nbcq1b1B"

    func testHashedKnownHostMatchesProceeds() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try (Self.hashedFixture + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.2.3.4",
                                            fingerprint: fp(Self.hashedFixturePub), store: store),
                       .proceed)
    }

    func testHashedKnownHostWrongHostNeedsTrust() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try (Self.hashedFixture + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(HostKeyGate.evaluate(host: "9.9.9.9",
                                            fingerprint: fp(Self.hashedFixturePub), store: store),
                       .needsTrust(sha256: "ab12"))
    }

    func testHashedKnownHostChangedKeyBlocked() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try (Self.hashedFixture + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.2.3.4",
                                            fingerprint: fp("DIFFERENTKEY"), store: store),
                       .blocked)
    }
}
#endif
