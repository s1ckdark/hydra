#if os(macOS)
import XCTest
@testable import Hydra

final class SSHKeyLocatorTests: XCTestCase {
    private func tempSSHDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hydra-ssh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ dir: URL, _ name: String, _ contents: String = "x") {
        try? contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testOrdersEd25519BeforeRsa() throws {
        let dir = tempSSHDir(); defer { try? FileManager.default.removeItem(at: dir) }
        write(dir, "id_rsa"); write(dir, "id_rsa.pub")
        write(dir, "id_ed25519"); write(dir, "id_ed25519.pub")
        let pairs = try SSHKeyLocator.orderedKeyPairs(in: dir)
        XCTAssertEqual(pairs.map { $0.publicURL.deletingPathExtension().lastPathComponent },
                       ["id_ed25519", "id_rsa"])
        XCTAssertEqual(pairs.first?.algorithmName, "ed25519")
    }

    func testExcludesPubWithoutPrivate() throws {
        let dir = tempSSHDir(); defer { try? FileManager.default.removeItem(at: dir) }
        write(dir, "id_ed25519"); write(dir, "id_ed25519.pub")
        write(dir, "id_ecdsa.pub")  // 개인키 없음 → 제외
        let pairs = try SSHKeyLocator.orderedKeyPairs(in: dir)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.privatePath.hasSuffix("id_ed25519"), true)
    }

    func testEmptyThrowsNoKeysFound() {
        let dir = tempSSHDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try SSHKeyLocator.orderedKeyPairs(in: dir)) { err in
            guard case SSHKeyLocator.LocateError.noKeysFound = err else {
                return XCTFail("expected noKeysFound, got \(err)")
            }
        }
    }

    func testDefaultPrivateKeyMatchesFirst() throws {
        // 실제 ~/.ssh 를 읽기 전용으로만 사용. 키 없으면 skip.
        guard let pairs = try? SSHKeyLocator.orderedKeyPairs(), let first = pairs.first else {
            throw XCTSkip("no ~/.ssh keys on this machine")
        }
        XCTAssertEqual(try SSHKeyLocator.defaultPrivateKeyPath(), first.privatePath)
    }
}
#endif
