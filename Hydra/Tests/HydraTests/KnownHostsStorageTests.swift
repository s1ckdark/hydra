import XCTest
import KnownHosts
@testable import Hydra

final class KnownHostsStorageTests: XCTestCase {
    private let entry = KnownHostsEntry(hostPattern: "fixture.invalid", keyType: "ssh-ed25519", publicKey: "AAAAFIXTURE")

    func testFirstTrustCreatesMissingParentDirectory() throws {
        try fixture { dir in
            let file = dir.appendingPathComponent("nested/SSH/known_hosts")
            let store = KnownHostsStore(fileURL: file)
            try store.trust(entry)
            XCTAssertEqual(try KnownHostsStore(fileURL: file).check(entry), .match)
        }
    }

    func testLegacyPinsMigrateWithoutChangingTheirBytesOrDeletingSource() throws {
        try fixture { dir in
            let legacy = dir.appendingPathComponent("legacy_known_hosts")
            let body = Data("# keep this comment\nfixture.invalid ssh-ed25519 AAAAFIXTURE".utf8)
            try body.write(to: legacy)
            let file = dir.appendingPathComponent("Application Support/Hydra/SSH/known_hosts")
            let store = KnownHostsStore(fileURL: file, legacyFileURL: legacy)
            XCTAssertEqual(try store.check(entry), .match)
            XCTAssertEqual(try Data(contentsOf: legacy), body)
            XCTAssertEqual(try Data(contentsOf: file), body)
            XCTAssertEqual(try store.check(.init(hostPattern: entry.hostPattern, keyType: entry.keyType, publicKey: "CHANGED")), .mismatch)
            try store.trust(.init(hostPattern: "second.invalid", keyType: "ssh-ed25519", publicKey: "BBBB"))
            XCTAssertEqual(try Data(contentsOf: legacy), body)
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("AAAAFIXTURE\nsecond.invalid"))
        }
    }

    func testExistingCanonicalStoreIsNotOverwrittenByRecoveryCopy() throws {
        try fixture { dir in
            let legacy = dir.appendingPathComponent("legacy")
            let file = dir.appendingPathComponent("current")
            try Data("fixture.invalid ssh-ed25519 OLD\n".utf8).write(to: legacy)
            try Data("fixture.invalid ssh-ed25519 AAAAFIXTURE\n".utf8).write(to: file)
            let store = KnownHostsStore(fileURL: file, legacyFileURL: legacy)
            XCTAssertEqual(try store.check(entry), .match)
            XCTAssertEqual(try store.check(.init(hostPattern: entry.hostPattern, keyType: entry.keyType, publicKey: "OLD")), .mismatch)
        }
    }

    func testUnreadableOrCorruptLegacyStoreDoesNotBecomeUnknown() throws {
        for isDirectory in [false, true] {
            try fixture { dir in
                let legacy = dir.appendingPathComponent("legacy")
                if isDirectory { try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true) }
                else { try Data([0xff, 0xfe, 0xff]).write(to: legacy) }
                let file = dir.appendingPathComponent("new/known_hosts")
                let store = KnownHostsStore(fileURL: file, legacyFileURL: legacy)
                XCTAssertThrowsError(try store.check(entry))
                XCTAssertThrowsError(try store.trust(entry))
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hydra-trust-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
