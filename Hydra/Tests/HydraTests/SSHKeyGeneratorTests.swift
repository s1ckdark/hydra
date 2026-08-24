import XCTest
@testable import Hydra

final class SSHKeyGeneratorTests: XCTestCase {

    func testPrivateKeyFormatAndIOSStorageValidation() {
        let key = SSHKeyGenerator.generate(comment: "test@hydra")
        XCTAssertTrue(key.privateKeyOpenSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(key.privateKeyOpenSSH.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        // iOS KeyImportScreen.save()의 저장 검증과 동일한 조건
        XCTAssertTrue(key.privateKeyOpenSSH.contains("PRIVATE KEY-----"))
        XCTAssertTrue(key.publicKeyLine.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(key.publicKeyLine.hasSuffix(" test@hydra"))
        XCTAssertFalse(key.publicKeyLine.contains("\n"))
    }

    /// OpenSSH 자체를 오라클로 사용: ssh-keygen -y가 개인키를 파싱해
    /// 낸 공개키가 우리가 만든 publicKeyLine과 일치해야 한다.
    func testSSHKeygenOracleAcceptsGeneratedKey() throws {
        let key = SSHKeyGenerator.generate(comment: "oracle@hydra")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkeygen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let privURL = dir.appendingPathComponent("id_ed25519")
        try key.privateKeyOpenSSH.write(to: privURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: privURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-y", "-f", privURL.path]
        let stdout = Pipe(); let stderr = Pipe()
        proc.standardOutput = stdout; proc.standardError = stderr
        try proc.run(); proc.waitUntilExit()

        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "ssh-keygen -y 실패: \(errText)")

        let derived = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        // ssh-keygen -y는 comment를 생략할 수 있으므로 타입+base64만 비교
        let expected = key.publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")
        let got = derived.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(got, expected)
    }

    func testGeneratedKeysAreUnique() {
        let a = SSHKeyGenerator.generate(comment: "c")
        let b = SSHKeyGenerator.generate(comment: "c")
        XCTAssertNotEqual(a.publicKeyLine, b.publicKeyLine)
    }

    #if os(macOS)
    func testInstallWritesKeyPairWithPermissionsAndRefusesOverwrite() throws {
        // NSTemporaryDirectory()는 /var/... (심볼릭 링크) 형태를 반환하지만
        // FileManager.contentsOfDirectory는 /private/var/...로 정규화된 경로를
        // 돌려준다. realpath로 미리 정규화해 두 경로가 문자열 레벨에서 일치하게 만든다.
        var realBuf = [Int8](repeating: 0, count: Int(PATH_MAX))
        realpath(NSTemporaryDirectory(), &realBuf)
        let resolvedTmp = URL(fileURLWithPath: String(cString: realBuf))
        let dir = resolvedTmp.appendingPathComponent("sshinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 디렉터리가 없어도 0700으로 만들어야 함
        let located = try SSHKeyGenerator.generateAndInstall(comment: "install@test", sshDir: dir)
        XCTAssertEqual(located.filename, "id_ed25519.pub")

        let fm = FileManager.default
        let privPath = dir.appendingPathComponent("id_ed25519").path
        let pubPath = dir.appendingPathComponent("id_ed25519.pub").path
        func perms(_ p: String) throws -> Int {
            (try fm.attributesOfItem(atPath: p)[.posixPermissions] as! NSNumber).intValue
        }
        XCTAssertEqual(try perms(dir.path), 0o700)
        XCTAssertEqual(try perms(privPath), 0o600)
        XCTAssertEqual(try perms(pubPath), 0o644)

        // SSHKeyLocator가 인식해야 함
        let pairs = try SSHKeyLocator.orderedKeyPairs(in: dir)
        XCTAssertEqual(pairs.first?.privatePath, privPath)
        XCTAssertEqual(pairs.first?.algorithmName, "ed25519")

        // 이미 존재하면 덮어쓰지 않고 실패해야 함
        XCTAssertThrowsError(try SSHKeyGenerator.generateAndInstall(comment: "x", sshDir: dir))
    }

    func testInstallRefusesWhenOnlyOneFileExists() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sshinstall-one-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // 개인키만 존재
        let privURL = dir.appendingPathComponent("id_ed25519")
        try "stale".write(to: privURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SSHKeyGenerator.generateAndInstall(comment: "x", sshDir: dir))
        // 기존 파일은 건드리지 않아야 함
        XCTAssertEqual(try String(contentsOf: privURL, encoding: .utf8), "stale")

        // 공개키만 존재
        try fm.removeItem(at: privURL)
        let pubURL = dir.appendingPathComponent("id_ed25519.pub")
        try "stale-pub".write(to: pubURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SSHKeyGenerator.generateAndInstall(comment: "x", sshDir: dir))
        XCTAssertEqual(try String(contentsOf: pubURL, encoding: .utf8), "stale-pub")
        XCTAssertFalse(fm.fileExists(atPath: privURL.path), "거부 시 개인키를 생성하면 안 됨")
    }

    func testInstallRollsBackBothFilesWhenPublicKeyPermissionFails() throws {
        struct PermissionFailure: Error {}

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sshinstall-rollback-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }

        XCTAssertThrowsError(
            try SSHKeyGenerator.generateAndInstall(
                comment: "rollback@test",
                sshDir: dir,
                setPermissions: { permissions, path in
                    if path.hasSuffix(".pub") { throw PermissionFailure() }
                    try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
                }
            )
        )

        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("id_ed25519").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("id_ed25519.pub").path))
    }
    #endif
}
