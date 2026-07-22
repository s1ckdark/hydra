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
}
