#if os(macOS)
import XCTest
import SSHTransport
import SSHTransportCitadel
import KnownHosts
@testable import Hydra

final class SSHKeyRegistrationCommandTests: XCTestCase {
    private let marker = "HYDRA_KEY_TEST_123"

    func testTargetRejectsAmbiguousHostsAndUnsafeUsers() throws {
        for host in ["host,other", "-option", "host\nother", "a b", "|1|salt|hash", "[host]:22", "host/path"] {
            XCTAssertThrowsError(try SSHKeyRegistrationTarget(host: host, user: "tester").validate())
        }
        for user in ["", "root';touch injected;#", "two words", "-root", "a\nroot"] {
            XCTAssertThrowsError(try SSHKeyRegistrationTarget(host: "127.0.0.1", user: user).validate())
        }
        XCTAssertThrowsError(try SSHKeyRegistrationTarget(host: "host", user: "tester", port: 0).validate())
        XCTAssertEqual(SSHKeyRegistrationTarget(host: "::1", user: "tester", port: 2222).knownHostIdentity, "[::1]:2222")
        XCTAssertEqual(SSHKeyRegistrationTarget(host: "host", user: "tester").knownHostIdentity, "host")
    }

    func testMalformedPublicKeyAndMultilineKeyAreRejected() {
        let valid = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
        for key in ["", "ssh-ed25519 AAAA", "ssh-rsa !!!", valid + "\nssh-ed25519 AAAA", valid + "\u{0}"] {
            XCTAssertThrowsError(try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker))
        }
        XCTAssertThrowsError(try SSHKeyRegistrationCommand.make(publicKeyLine: valid, expectedUser: "root';id;#", marker: marker))
    }

    func testAppendPreservesExistingBytesAndMissingFinalNewline() throws {
        try withFixture { dir in
            let ssh = dir.appendingPathComponent(".ssh")
            try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
            let file = ssh.appendingPathComponent("authorized_keys")
            let old = "# existing data without a final newline"
            try Data(old.utf8).write(to: file)
            let key = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
            let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker)
            let result = try run(command, home: dir)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(result.output, marker + ":added\n")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), old + "\n" + key + "\n")
            XCTAssertEqual(try permissions(ssh), 0o700)
            XCTAssertEqual(try permissions(file), 0o600)
        }
    }

    func testRestrictedExistingMaterialIsNeverDuplicatedWithUnrestrictedKey() throws {
        try withFixture { dir in
            let key = SSHKeyGenerator.generate(comment: "new comment").publicKeyLine
            let material = key.split(separator: " ").prefix(2).joined(separator: " ")
            let old = "restrict,command=\"printf restricted\" " + material + " previous comment\n"
            let ssh = dir.appendingPathComponent(".ssh")
            try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
            let file = ssh.appendingPathComponent("authorized_keys")
            try Data(old.utf8).write(to: file)
            let result = try run(SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker), home: dir)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(result.output, marker + ":exists\n")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), old)
        }
    }

    func testCommentShellMetacharactersRemainLiteralAndSecondRegistrationIsIdempotent() throws {
        try withFixture { dir in
            let key = SSHKeyGenerator.generate(comment: "' $(touch injected) `touch injected2` ; # test").publicKeyLine
            let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker)
            XCTAssertEqual(try run(command, home: dir).status, 0)
            XCTAssertEqual(try run(command, home: dir).output, marker + ":exists\n")
            let file = dir.appendingPathComponent(".ssh/authorized_keys")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), key + "\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("injected").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("injected2").path))
        }
    }

    func testRestrictedCRLFEntryWithoutCommentIsNotDuplicated() throws {
        try withFixture { dir in
            let key = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
            let material = key.split(separator: " ").prefix(2).joined(separator: " ")
            let original = "restrict " + material + "\r\n"
            let ssh = dir.appendingPathComponent(".ssh")
            try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
            let file = ssh.appendingPathComponent("authorized_keys")
            try Data(original.utf8).write(to: file)
            let result = try run(SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker), home: dir)
            XCTAssertEqual(result.output, marker + ":exists\n")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        }
    }

    func testWrongAccountDoesNotCreateSSHDirectory() throws {
        try withFixture { dir in
            let key = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
            let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: "hydra-wrong-account", marker: marker)
            XCTAssertEqual(try run(command, home: dir).status, 20)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ssh").path))
        }
    }

    func testSSHDirectoryCreationPermissionFailureHasItsOwnStatus() throws {
        try withFixture { dir in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            let key = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
            let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker)
            XCTAssertEqual(try run(command, home: dir).status, 30)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ssh").path))
        }
    }

    func testRefusesSSHDirectoryAndAuthorizedKeysSymlinks() throws {
        for linkDirectory in [true, false] {
            try withFixture { dir in
                let elsewhere = dir.appendingPathComponent("elsewhere")
                let ssh = dir.appendingPathComponent(".ssh")
                if linkDirectory {
                    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: ssh, withDestinationURL: elsewhere)
                } else {
                    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
                    try Data("untouched".utf8).write(to: elsewhere)
                    try FileManager.default.createSymbolicLink(at: ssh.appendingPathComponent("authorized_keys"), withDestinationURL: elsewhere)
                }
                let key = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
                let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker)
                XCTAssertNotEqual(try run(command, home: dir).status, 0)
                if !linkDirectory { XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "untouched") }
            }
        }
    }

    func testRefusesNonregularAuthorizedKeys() throws {
        try withFixture { dir in
            let file = dir.appendingPathComponent(".ssh/authorized_keys")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            let key = SSHKeyGenerator.generate(comment: "fixture").publicKeyLine
            let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key, expectedUser: NSUserName(), marker: marker)
            XCTAssertNotEqual(try run(command, home: dir).status, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hydra-registration-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    private func run(_ script: String, home: URL) throws -> (status: Int32, output: String) {
        // Only a test-local variable is changed; the process/user HOME is never reassigned.
        XCTAssertTrue(script.contains("$HOME"))
        let fixtureScript = script.replacingOccurrences(of: "$HOME", with: "$HYDRA_TEST_HOME")
            .replacingOccurrences(of: "${HOME:-}", with: "${HYDRA_TEST_HOME:-}")
        XCTAssertFalse(fixtureScript.contains("$HOME"))
        XCTAssertFalse(fixtureScript.contains("${HOME"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", fixtureScript]
        process.currentDirectoryURL = home
        process.environment = ["HYDRA_TEST_HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
}

@MainActor
final class SSHKeyRegistrationServiceTests: XCTestCase {
    private let fingerprint = HostKeyFingerprint(keyType: "ssh-ed25519", publicKeyBase64: "fixture-key", sha256Hex: "0123")

    func testRejectedHostNeverAuthenticatesOrExecutes() async throws {
        try await withService { service, sessions, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in false }, onProgress: { _ in })
                XCTFail("must reject")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .hostRejected) }
            XCTAssertEqual(sessions().count, 1)
            XCTAssertEqual(sessions().first?.authentications.count, 0)
            XCTAssertEqual(sessions().first?.commands.count, 0)
        }
    }

    func testMismatchFailsClosedWithoutApprovalOrPassword() async throws {
        try await withService { service, sessions, file in
            try KnownHostsStore(fileURL: file).trust(.init(hostPattern: "host", keyType: "ssh-ed25519", publicKey: "different-key"))
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in XCTFail("mismatch must not prompt"); return true }, onProgress: { _ in })
                XCTFail("must reject")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .hostMismatch) }
            XCTAssertEqual(sessions().first?.authentications.count, 0)
        }
    }

    func testSuccessfulRegistrationRequiresIndependentPrivateKeyAuthentication() async throws {
        try await withService { service, sessions, file in
            let key = privateKey()
            let result = try await service.register(target: .init(host: "host", user: "tester", port: 2222), privateKey: key, password: "secret", approveHost: { _ in true }, onProgress: { _ in })
            XCTAssertFalse(result.alreadyRegistered)
            XCTAssertEqual(sessions().count, 3)
            XCTAssertEqual(sessions()[0].authentications, [])
            XCTAssertEqual(sessions()[1].authentications, [.password("secret")])
            XCTAssertEqual(sessions()[2].authentications, [.privateKey(key, passphrase: nil)])
            XCTAssertEqual(sessions()[1].commands.count, 1)
            XCTAssertEqual(try KnownHostsStore(fileURL: file).check(.init(hostPattern: "[host]:2222", keyType: fingerprint.keyType, publicKey: fingerprint.publicKeyBase64)), .match)
        }
    }

    func testCancellationWhileHostPromptPendingPreventsTrustAndRemoteWrite() async throws {
        try await withService { service, sessions, file in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in service.cancel(); return true }, onProgress: { _ in })
                XCTFail("must cancel")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .cancelled(mayHaveRegistered: false)) }
            XCTAssertEqual(sessions().first?.commands.count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testFailedKeyLoginReportsPartialRegistration() async throws {
        try await withService(failVerification: true) { service, _, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                XCTFail("must not report success")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .keyLoginFailed(.authenticationRejected)) }
        }
    }

    func testMalformedPrivateKeyMakesNoConnection() async throws {
        try await withService { service, sessions, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: Data("invalid".utf8), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                XCTFail("must reject malformed key")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .invalidPublicKey) }
            XCTAssertTrue(sessions().isEmpty)
        }
    }

    func testUnreadableKnownHostsFailsClosedWithoutApprovalOrAuthentication() async throws {
        try await withService { service, sessions, file in
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in XCTFail("must not prompt when trust store cannot be read"); return true }, onProgress: { _ in })
                XCTFail("must fail closed")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .trustStoreUnavailable) }
            XCTAssertEqual(sessions().first?.authentications.count, 0)
            XCTAssertEqual(sessions().first?.commands.count, 0)
        }
    }

    func testEchoedMarkerOrExtraOutputCannotReportSuccess() async throws {
        try await withService(configure: { _, session in session.outputPrefix = "unexpected output\n" }) { service, sessions, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                XCTFail("must not accept noisy output")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .verificationFailed(mayHaveRegistered: true)) }
            XCTAssertEqual(sessions().count, 2)
        }
    }

    func testConnectionFailureIsPreservedBeforeAnyRemoteCommand() async throws {
        for reason in [SSHFailure.connectionRefused, .nameResolutionFailed, .timedOut,
                       .networkUnavailable, .authenticationRejected, .passwordAuthenticationUnsupported] {
            try await withService(configure: { index, session in
                if index == 1 { session.connectFailure = reason }
            }) { service, sessions, _ in
                do {
                    _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                    XCTFail("must report the connection cause")
                } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .connectionFailed(reason)) }
                XCTAssertTrue(sessions().allSatisfy { $0.commands.isEmpty })
            }
        }
    }

    func testRemoteCommandExitIsPreservedWithoutClaimingKeyLoginFailure() async throws {
        for status in [20, 21, 22, 23, 25, 26, 27, 28, 30, 31, 127] {
            try await withService(configure: { _, session in
                session.execFailure = SSHFailure.commandFailed(exitStatus: status)
            }) { service, sessions, _ in
                do {
                    _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                    XCTFail("must report remote exit")
                } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .remoteCommandFailed(exitStatus: status)) }
                XCTAssertEqual(sessions().count, 2, "Key login must not start after failed command")
            }
        }
    }

    func testConnectionLossDuringAppendRetainsCauseAndUncertainty() async throws {
        try await withService(configure: { _, session in session.execFailure = SSHFailure.connectionLost }) { service, _, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                XCTFail("must report interrupted append")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .registrationInterrupted(.connectionLost)) }
        }
    }

    func testFreshKeyLoginConnectionFailureIsSeparateFromRegistrationFailure() async throws {
        try await withService(configure: { index, session in
            if index == 2 { session.connectFailure = SSHFailure.connectionRefused }
        }) { service, _, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { _ in })
                XCTFail("must report key login failure after acknowledged append")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .keyLoginFailed(.connectionRefused)) }
        }
    }

    func testDescriptionsExplainCauseAndActionWithoutBlamingPasswordForNetworkErrors() {
        let refusal = SSHKeyRegistrationError.connectionFailed(.connectionRefused).localizedDescription
        XCTAssertTrue(refusal.contains("연결을 거부"))
        XCTAssertTrue(refusal.contains("SSH 서비스"))
        XCTAssertFalse(refusal.contains("비밀번호"))
        let unsupported = SSHKeyRegistrationError.connectionFailed(.passwordAuthenticationUnsupported).localizedDescription
        XCTAssertTrue(unsupported.contains("비밀번호 인증"))
        XCTAssertTrue(unsupported.contains("서버 등록 명령 복사"))
        let denied = SSHKeyRegistrationError.connectionFailed(.authenticationRejected).localizedDescription
        XCTAssertTrue(denied.contains("계정"))
        XCTAssertTrue(denied.contains("정책"))
        XCTAssertFalse(denied.contains("비밀번호가 틀"))
        let permissions = SSHKeyRegistrationError.remoteCommandFailed(exitStatus: 26).localizedDescription
        XCTAssertTrue(permissions.contains("권한"))
        XCTAssertFalse(permissions.contains("비밀번호"))
        let interrupted = SSHKeyRegistrationError.registrationInterrupted(.connectionLost).localizedDescription
        XCTAssertTrue(interrupted.contains("추가되었을 수"))
        let verification = SSHKeyRegistrationError.keyLoginFailed(.authenticationRejected).localizedDescription
        XCTAssertTrue(verification.contains("등록은 확인"))
        XCTAssertTrue(verification.contains("키 로그인"))
    }

    func testCancellationAfterAppendSubmissionReportsUncertaintyAndDoesNotVerify() async throws {
        try await withService { service, sessions, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { progress in
                    if progress == .registering { sessions().last?.onExec = { service.cancel() } }
                })
                XCTFail("must cancel")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .cancelled(mayHaveRegistered: true)) }
            XCTAssertEqual(sessions().count, 2)
            XCTAssertEqual(sessions().last?.commands.count, 1)
        }
    }

    func testCancellationAtConnectedProgressDoesNotSubmitAppend() async throws {
        try await withService { service, sessions, _ in
            do {
                _ = try await service.register(target: .init(host: "host", user: "tester"), privateKey: privateKey(), password: "secret", approveHost: { _ in true }, onProgress: { progress in
                    if progress == .registering { service.cancel() }
                })
                XCTFail("must cancel")
            } catch { XCTAssertEqual(error as? SSHKeyRegistrationError, .cancelled(mayHaveRegistered: false)) }
            XCTAssertTrue(sessions().allSatisfy { $0.commands.isEmpty })
        }
    }

    private func privateKey() -> Data { Data(SSHKeyGenerator.generate(comment: "fixture").privateKeyOpenSSH.utf8) }

    private func withService(failVerification: Bool = false, configure: @escaping (Int, RegistrationFakeSession) -> Void = { _, _ in }, body: (SSHKeyRegistrationService, @escaping () -> [RegistrationFakeSession], URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hydra-registration-service-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        var sessions: [RegistrationFakeSession] = []
        let service = SSHKeyRegistrationService(knownHostsURL: file) { verifier in
            let session = RegistrationFakeSession(fingerprint: self.fingerprint, verifier: verifier, failAuth: failVerification && sessions.count == 2)
            configure(sessions.count, session)
            sessions.append(session)
            return session
        }
        try await body(service, { sessions }, file)
    }
}

private final class RegistrationFakeSession: SSHSession {
    let output = AsyncStream<Data> { $0.finish() }
    let state = AsyncStream<SSHState> { $0.finish() }
    let remoteHostKey: HostKeyFingerprint?
    let verifier: SSHHostKeyVerifier
    let failAuth: Bool
    var authentications: [SSHAuth] = []
    var commands: [String] = []
    var outputPrefix = ""
    var onExec: (@MainActor () -> Void)?
    var connectFailure: Error?
    var execFailure: Error?
    init(fingerprint: HostKeyFingerprint, verifier: @escaping SSHHostKeyVerifier, failAuth: Bool) {
        remoteHostKey = fingerprint
        self.verifier = verifier
        self.failAuth = failAuth
    }
    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {
        try await verifier(remoteHostKey!)
        if let connectFailure { throw connectFailure }
        if failAuth { throw SSHFailure.authenticationRejected }
        authentications.append(auth)
    }
    func exec(_ command: String) async throws -> String {
        commands.append(command)
        await onExec?()
        if let execFailure { throw execFailure }
        guard let range = command.range(of: "HYDRA_KEY_[A-Za-z0-9_]+", options: .regularExpression) else { return "" }
        return outputPrefix + String(command[range]) + ":added\n"
    }
    func openShell(termType: String, cols: Int, rows: Int) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func disconnect() {}
}
#endif
