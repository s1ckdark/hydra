#if os(macOS)
import XCTest
import SSHTransport
import SSHTransportCitadel
@testable import Hydra

/// Runs only via the generated-password localhost fixture; never uses personal SSH credentials.
@MainActor
final class SSHKeyRegistrationIntegrationTests: XCTestCase {
    func testPasswordBootstrapRegistersKeyThenFreshKeyLoginAndIdempotentRetry() async throws {
        let fixture = try fixture()
        let seed = CitadelSession(hostKeyVerifier: { _ in })
        defer { seed.disconnect() }
        try await seed.connect(host: fixture.host, port: fixture.port, user: fixture.user,
                               auth: .privateKey(fixture.seed, passphrase: nil))
        let original = try await seed.execDirect("cat \"$HOME/.ssh/authorized_keys\"")
        let knownHosts = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-registration-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: knownHosts) }
        let candidate = SSHKeyGenerator.generate(comment: "disposable-registration-candidate")
        let service = SSHKeyRegistrationService(knownHostsURL: knownHosts)
        var approvals = 0
        let result = try await service.register(
            target: .init(host: fixture.host, user: fixture.user, port: fixture.port),
            privateKey: Data(candidate.privateKeyOpenSSH.utf8), password: fixture.password,
            approveHost: { fingerprint in
                approvals += 1
                return fingerprint == seed.remoteHostKey
            }, onProgress: { _ in })
        XCTAssertFalse(result.alreadyRegistered)
        XCTAssertEqual(approvals, 1)
        let installed = try await seed.execDirect("cat \"$HOME/.ssh/authorized_keys\"")
        XCTAssertTrue(installed.hasPrefix(original), "Original authorized entries must remain unchanged")
        let publicMaterial = candidate.publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(installed.components(separatedBy: "\n").filter { $0.hasPrefix(publicMaterial) }.count, 1)
        let retry = try await service.register(
            target: .init(host: fixture.host, user: fixture.user, port: fixture.port),
            privateKey: Data(candidate.privateKeyOpenSSH.utf8), password: fixture.password,
            approveHost: { _ in XCTFail("Known host must not prompt again"); return false }, onProgress: { _ in })
        XCTAssertTrue(retry.alreadyRegistered)
        let afterRetry = try await seed.execDirect("cat \"$HOME/.ssh/authorized_keys\"")
        XCTAssertEqual(afterRetry, installed)
    }

    func testRejectingRealHostOccursBeforePasswordAuthentication() async throws {
        let fixture = try fixture()
        let session = CitadelSession(hostKeyVerifier: { _ in throw FixtureRejection.rejected })
        defer { session.disconnect() }
        do {
            try await session.connect(host: fixture.host, port: fixture.port, user: fixture.user,
                                      auth: .password("intentionally-invalid-disposable-fixture-password"))
            XCTFail("Rejected host must never authenticate")
        } catch {
            XCTAssertTrue(error is FixtureRejection, "Host rejection must precede authentication failure")
        }
    }

    func testWrongPasswordReturnsAuthenticationRejectionWithoutRegisteringKey() async throws {
        let fixture = try fixture()
        let seed = CitadelSession(hostKeyVerifier: { _ in })
        defer { seed.disconnect() }
        try await seed.connect(host: fixture.host, port: fixture.port, user: fixture.user,
                               auth: .privateKey(fixture.seed, passphrase: nil))
        let before = try await seed.execDirect("cat \"$HOME/.ssh/authorized_keys\"")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hydra-error-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = SSHKeyGenerator.generate(comment: "invalid-password-fixture")
        let service = SSHKeyRegistrationService(knownHostsURL: file)
        do {
            _ = try await service.register(target: .init(host: fixture.host, user: fixture.user, port: fixture.port),
                privateKey: Data(key.privateKeyOpenSSH.utf8), password: "invalid-disposable-password",
                approveHost: { $0 == seed.remoteHostKey }, onProgress: { _ in })
            XCTFail("Invalid fixture password must be rejected")
        } catch {
            XCTAssertEqual(error as? SSHKeyRegistrationError, .connectionFailed(.authenticationRejected))
        }
        let after = try await seed.execDirect("cat \"$HOME/.ssh/authorized_keys\"")
        XCTAssertEqual(after, before)
    }

    func testRemoteAccountGuardReturnsItsExitStatus() async throws {
        let fixture = try fixture()
        let session = CitadelSession(hostKeyVerifier: { _ in })
        defer { session.disconnect() }
        try await session.connect(host: fixture.host, port: fixture.port, user: fixture.user,
                                  auth: .privateKey(fixture.seed, passphrase: nil))
        let key = SSHKeyGenerator.generate(comment: "wrong-account-fixture")
        let command = try SSHKeyRegistrationCommand.make(publicKeyLine: key.publicKeyLine,
            expectedUser: "hydra-wrong-account", marker: "HYDRA_KEY_WRONG_ACCOUNT_TEST")
        do {
            _ = try await session.execDirect(command)
            XCTFail("Account mismatch must fail before changing authorized_keys")
        } catch { XCTAssertEqual(error as? SSHFailure, .commandFailed(exitStatus: 20)) }
    }

    private func fixture() throws -> (host: String, port: Int, user: String, password: String, seed: Data) {
        let env = ProcessInfo.processInfo.environment
        guard env["HYDRA_CITADEL_SMOKE_FIXTURE"] == "disposable-localhost",
              env["HYDRA_CITADEL_SMOKE_HOST"] == "127.0.0.1",
              let portValue = env["HYDRA_CITADEL_SMOKE_PORT"], let port = Int(portValue),
              let keyPath = env["HYDRA_CITADEL_SMOKE_KEY"],
              let password = env["HYDRA_CITADEL_SMOKE_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Run with Tests/smoke/citadel-input-integration.sh disposable fixture")
        }
        return ("127.0.0.1", port, "smoke", password, try Data(contentsOf: URL(fileURLWithPath: keyPath)))
    }
}

private enum FixtureRejection: Error { case rejected }
#endif
