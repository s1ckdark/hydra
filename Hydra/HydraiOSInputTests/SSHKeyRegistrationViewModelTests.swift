import XCTest
import SSHTransport
@testable import HydraiOS

@MainActor
final class SSHKeyRegistrationViewModelTests: XCTestCase {
    private let testKey = SSHKeyGenerator.generate(comment: "registration-ui-test")

    func testFailureTargetSurvivesMissingKeyAndKeyReload() async {
        var key: Data?
        let expected = SSHKeyRegistrationTarget(host: "100.64.0.77", user: "attempt-user", port: 2222)
        let model = SSHKeyRegistrationViewModel(initialUsername: "different-settings-user", initialTarget: expected,
            keyProvider: { key }, service: RegistrationServiceDouble(), devicesProvider: { [] })
        await model.load()
        XCTAssertEqual(model.host, expected.host)
        XCTAssertEqual(model.username, expected.user)
        XCTAssertEqual(model.port, expected.port)
        XCTAssertFalse(model.canRequestRegistration)
        key = Data(testKey.privateKeyOpenSSH.utf8)
        await model.load()
        model.password = "fixture-only-password"
        model.requestRegistration()
        XCTAssertEqual(model.confirmation?.target, expected)
    }

    func testRequiresSavedParseableKeyExplicitTargetAccountAndPassword() async {
        let service = RegistrationServiceDouble()
        var key: Data?
        let model = makeModel(service: service, username: "", keyProvider: { key })
        await model.load()
        model.host = "server.example"
        model.password = "test-only-password"
        XCTAssertFalse(model.canRequestRegistration)
        XCTAssertEqual(model.username, "", "An empty account must not silently become root")

        key = Data("not a private key".utf8)
        await model.load()
        model.username = "alice"
        XCTAssertFalse(model.canRequestRegistration)

        key = Data(testKey.privateKeyOpenSSH.utf8)
        await model.load()
        XCTAssertTrue(model.canRequestRegistration)
        model.host = ""
        XCTAssertFalse(model.canRequestRegistration)
        model.host = "server.example"
        model.password = ""
        XCTAssertFalse(model.canRequestRegistration)
        XCTAssertEqual(service.calls, 0)
    }

    func testExplicitConfirmationSnapshotsTargetAndClearsPasswordAtSubmission() async {
        let service = RegistrationServiceDouble()
        let model = makeModel(service: service)
        await model.load()
        model.host = "server.example"
        model.password = "test-only-password"
        model.requestRegistration()
        XCTAssertEqual(service.calls, 0)
        XCTAssertEqual(model.confirmation?.target, .init(host: "server.example", user: "alice"))
        XCTAssertEqual(model.confirmation?.publicKeyLine, model.publicKeyLine)
        XCTAssertFalse(model.confirmation?.fingerprint.isEmpty ?? true)

        // Even if a caller changes the form, only the explicitly confirmed target is used.
        model.host = "different.example"
        model.username = "root"
        model.confirmRegistration()
        XCTAssertEqual(model.password, "")
        await waitUntil { service.calls == 1 }
        XCTAssertEqual(service.target, .init(host: "server.example", user: "alice"))
        XCTAssertEqual(service.receivedPassword, "test-only-password")
        service.finish(.success(.init(alreadyRegistered: false)))
        await waitUntil { !model.isRegistering }
        XCTAssertEqual(model.registrationResult, .init(alreadyRegistered: false))
    }

    func testCancelConfirmationClearsPasswordWithoutCallingService() async {
        let service = RegistrationServiceDouble()
        let model = makeModel(service: service)
        await model.load()
        model.host = "server.example"
        model.password = "test-only-password"
        model.requestRegistration()
        model.cancel()
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(service.calls, 0)
    }

    func testBackgroundClearsPasswordAndInvalidatesPendingConfirmation() async {
        let service = RegistrationServiceDouble()
        let model = makeModel(service: service)
        await begin(model, confirm: false)
        model.close()
        model.confirmRegistration()
        await Task.yield()
        XCTAssertEqual(model.password, "")
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(service.calls, 0)
    }

    func testUnsafeTargetDisablesBothRegistrationAndManualCommand() async {
        let model = makeModel(service: RegistrationServiceDouble())
        await model.load()
        model.host = "server.example,other.example"
        model.password = "test-only-password"
        XCTAssertFalse(model.canRequestRegistration)
        XCTAssertThrowsError(try model.manualRegistrationCommand())
        model.host = "server.example"
        model.username = "root';id;#"
        XCTAssertFalse(model.canRequestRegistration)
        XCTAssertThrowsError(try model.manualRegistrationCommand())
    }

    func testCloseRejectsPendingHostApprovalAndIgnoresLateCompletion() async {
        let service = RegistrationServiceDouble()
        service.askForHostApproval = true
        let model = makeModel(service: service)
        await begin(model)
        await waitUntil { model.pendingHostKey != nil }
        XCTAssertNil(service.hostApproved)
        model.close()
        XCTAssertNil(model.pendingHostKey)
        XCTAssertEqual(model.password, "")
        XCTAssertFalse(model.isRegistering)
        await waitUntil { service.hostApproved != nil }
        XCTAssertEqual(service.hostApproved, false)
        service.finish(.success(.init(alreadyRegistered: false)))
        await Task.yield()
        XCTAssertNil(model.registrationResult)
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(service.cancelCalls, 1)
    }

    func testCancellationBeforeTaskStartsDoesNotBeginRegistration() async {
        let service = RegistrationServiceDouble()
        let model = makeModel(service: service)
        await begin(model, confirm: false)
        model.confirmRegistration()
        model.cancel()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.calls, 0, "A cancelled queued task must not begin a fresh registration")
        XCTAssertEqual(model.password, "")
        XCTAssertFalse(model.isRegistering)
        // Complete a mistakenly started fake operation so a RED run does not leak its continuation.
        service.finish(.success(.init(alreadyRegistered: false)))
    }

    func testHostApprovalRequiresExplicitUserDecision() async {
        let service = RegistrationServiceDouble()
        service.askForHostApproval = true
        let model = makeModel(service: service)
        await begin(model)
        await waitUntil { model.pendingHostKey != nil }
        XCTAssertNil(service.hostApproved)
        model.respondToHostKey(approve: true)
        await waitUntil { service.hostApproved != nil }
        XCTAssertEqual(service.hostApproved, true)
        XCTAssertNil(model.pendingHostKey)
        service.finish(.success(.init(alreadyRegistered: true)))
        await waitUntil { !model.isRegistering }
        XCTAssertEqual(model.registrationResult, .init(alreadyRegistered: true))
    }

    func testChangedKeyAfterConfirmationIsNotSilentlyRegistered() async {
        let service = RegistrationServiceDouble()
        var key = Data(testKey.privateKeyOpenSSH.utf8)
        let model = makeModel(service: service, keyProvider: { key })
        await begin(model, confirm: false)
        key = Data(SSHKeyGenerator.generate(comment: "replacement-ui-test").privateKeyOpenSSH.utf8)
        model.confirmRegistration()
        XCTAssertEqual(model.password, "")
        await Task.yield()
        XCTAssertEqual(service.calls, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testUntrustedErrorNeverDisplaysPasswordPrivateKeyOrRemoteErrorText() async {
        let service = RegistrationServiceDouble()
        let model = makeModel(service: service)
        await begin(model)
        await waitUntil { service.calls == 1 }
        service.finish(.failure(NSError(domain: "untrusted", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "test-only-password \(testKey.privateKeyOpenSSH)"])))
        await waitUntil { !model.isRegistering }
        let message = model.errorMessage ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("test-only-password"))
        XCTAssertFalse(message.contains("PRIVATE KEY"))
        XCTAssertEqual(model.password, "")
        XCTAssertNil(model.registrationResult)
    }

    func testUnverifiedRegistrationIsNotReportedAsSuccess() async {
        let service = RegistrationServiceDouble()
        let model = makeModel(service: service)
        await begin(model)
        await waitUntil { service.calls == 1 }
        service.finish(.failure(SSHKeyRegistrationError.verificationFailed(mayHaveRegistered: true)))
        await waitUntil { !model.isRegistering }
        XCTAssertNil(model.registrationResult)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("확인") ?? false)
    }

    func testChangingTargetClearsPreviousServersSuccess() async {
        for changeAccount in [false, true] {
            let service = RegistrationServiceDouble()
            let model = makeModel(service: service)
            await begin(model)
            await waitUntil { service.calls == 1 }
            service.finish(.success(.init(alreadyRegistered: false)))
            await waitUntil { model.registrationResult != nil }
            if changeAccount { model.username = "bob" }
            else { model.host = "other.example" }
            XCTAssertNil(model.registrationResult, "Success for one account must not label another account as registered")
        }
    }

    func testManualCommandContainsOnlyPublicKeyAndExpectedAccountGuard() async throws {
        let model = makeModel(service: RegistrationServiceDouble())
        await model.load()
        model.host = "server.example"
        let command = try model.manualRegistrationCommand()
        XCTAssertTrue(command.contains("alice"))
        XCTAssertTrue(command.contains("id -un"))
        XCTAssertFalse(command.contains("PRIVATE KEY"))
        XCTAssertFalse(command.contains("test-only-password"))
        XCTAssertFalse(command.contains("sudo"))
    }

    private func makeModel(service: RegistrationServiceDouble, username: String = "alice",
                           keyProvider: (() -> Data?)? = nil) -> SSHKeyRegistrationViewModel {
        let privateKey = Data(testKey.privateKeyOpenSSH.utf8)
        return SSHKeyRegistrationViewModel(initialUsername: username,
                                           keyProvider: keyProvider ?? { privateKey },
                                           service: service,
                                           devicesProvider: { [] })
    }

    private func begin(_ model: SSHKeyRegistrationViewModel, confirm: Bool = true) async {
        await model.load()
        model.host = "server.example"
        model.password = "test-only-password"
        model.requestRegistration()
        if confirm { model.confirmRegistration() }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for registration test state", file: file, line: line)
    }
}

@MainActor
private final class RegistrationServiceDouble: SSHKeyRegistering {
    var calls = 0
    var cancelCalls = 0
    var target: SSHKeyRegistrationTarget?
    var receivedPassword: String?
    var askForHostApproval = false
    var hostApproved: Bool?
    private var continuation: CheckedContinuation<SSHKeyRegistrationResult, Error>?

    func register(target: SSHKeyRegistrationTarget, privateKey: Data, password: String,
                  approveHost: @escaping @MainActor (HostKeyFingerprint) async -> Bool,
                  onProgress: @escaping @MainActor (SSHKeyRegistrationProgress) -> Void) async throws -> SSHKeyRegistrationResult {
        calls += 1
        self.target = target
        receivedPassword = password
        if askForHostApproval {
            onProgress(.awaitingHostApproval)
            hostApproved = await approveHost(.init(keyType: "ssh-ed25519", publicKeyBase64: "test-host", sha256Hex: "test-fingerprint"))
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() { cancelCalls += 1 }

    func finish(_ result: Result<SSHKeyRegistrationResult, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
