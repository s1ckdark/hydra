#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

final class VendoredTerminalCoreTests: XCTestCase {
    func testFakeSessionLinksAndConnects() async throws {
        let s = FakeSSHSession()
        try await s.connect(host: "h", port: 22, user: "u", auth: .password("x"))
        // remoteHostKey 스텁이 노출된다 (모듈 링크 확인)
        XCTAssertEqual(s.remoteHostKey?.keyType, "ssh-ed25519")
    }

    func testKnownHostsStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kh-\(UUID().uuidString)")
        let store = KnownHostsStore(fileURL: url)
        let e = KnownHostsEntry(hostPattern: "1.2.3.4", keyType: "ssh-ed25519", publicKey: "AAAAKEY")
        XCTAssertEqual(try store.check(e), .unknown)
        try store.trust(e)
        XCTAssertEqual(try store.check(e), .match)
        let e2 = KnownHostsEntry(hostPattern: "1.2.3.4", keyType: "ssh-ed25519", publicKey: "DIFFERENT")
        XCTAssertEqual(try store.check(e2), .mismatch)
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
