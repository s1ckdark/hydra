import XCTest
import KnownHosts

final class KnownHostsAppendTests: XCTestCase {
    func testAppendPreservesExistingFileWithAndWithoutFinalNewline() throws {
        for ending in ["", "\n"] {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("hydra-knownhosts-append-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            let first = "first.example ssh-ed25519 AAAA" + ending
            try Data(first.utf8).write(to: file)
            let store = KnownHostsStore(fileURL: file)
            try store.trust(.init(hostPattern: "second.example", keyType: "ssh-ed25519", publicKey: "BBBB"))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                           "first.example ssh-ed25519 AAAA\nsecond.example ssh-ed25519 BBBB\n")
            XCTAssertEqual(try store.check(.init(hostPattern: "first.example", keyType: "ssh-ed25519", publicKey: "AAAA")), .match)
            XCTAssertEqual(try store.check(.init(hostPattern: "second.example", keyType: "ssh-ed25519", publicKey: "BBBB")), .match)
        }
    }
}
