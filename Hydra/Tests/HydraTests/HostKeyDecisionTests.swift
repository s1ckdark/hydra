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
}
#endif
