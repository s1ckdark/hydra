#if os(macOS)
import XCTest
import SSHTransport
@testable import SSHTransportCitadel
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
@testable import Hydra

final class SSHRegistrationTransportTests: XCTestCase {
    func testDirectExecRequiresAnAuthenticatedConnection() async {
        let session = CitadelSession()
        do {
            _ = try await session.execDirect("printf registration-test")
            XCTFail("Direct exec must not run before authentication")
        } catch {
            XCTAssertEqual(error as? SSHError, .channelFailed("not connected"))
        }
        session.disconnect()
    }

    func testPasswordWithoutHostVerifierFailsBeforeConnecting() async {
        let session = CitadelSession()
        do {
            try await session.connect(host: "127.0.0.1", port: 0, user: "test",
                                      auth: .password("not-a-real-password"))
            XCTFail("An unverified host must never receive password authentication")
        } catch {
            XCTAssertEqual(error as? SSHError,
                           .handshakeFailed("Password authentication requires a host-key verifier."))
        }
        session.disconnect()
        var states: [SSHState] = []
        for await state in session.state { states.append(state) }
        XCTAssertFalse(states.contains(.connecting), "Preflight rejection must happen before connecting")
        XCTAssertNil(session.remoteHostKey)
    }

    func testPublicKeyIsDerivedFromEd25519PrivateMaterial() throws {
        let generated = SSHKeyGenerator.generate(comment: "registration-test")
        let derived = try CitadelSession.publicKeyLine(fromPrivateKey: Data(generated.privateKeyOpenSSH.utf8))
        XCTAssertEqual(derived, publicPart(generated.publicKeyLine))
        XCTAssertFalse(derived.contains("PRIVATE"))
        XCTAssertFalse(derived.contains("\n"))
    }

    func testPublicHeaderCannotSubstituteADifferentEd25519Key() throws {
        let actual = SSHKeyGenerator.generate(comment: "actual")
        let decoy = SSHKeyGenerator.generate(comment: "decoy")
        let payload = actual.privateKeyOpenSSH.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }.joined()
        var bytes = try XCTUnwrap(Data(base64Encoded: payload))
        let actualPublic = try XCTUnwrap(Data(base64Encoded: String(actual.publicKeyLine.split(separator: " ")[1])))
        let decoyPublic = try XCTUnwrap(Data(base64Encoded: String(decoy.publicKeyLine.split(separator: " ")[1])))
        let publicRange = try XCTUnwrap(bytes.range(of: actualPublic))
        bytes.replaceSubrange(publicRange, with: decoyPublic)
        let edited = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + bytes.base64EncodedString()
            + "\n-----END OPENSSH PRIVATE KEY-----\n"

        // The outer public header is untrusted. Parsing may reject the mismatch,
        // or derive the actual private key's public component, but never the decoy.
        do {
            let derived = try CitadelSession.publicKeyLine(fromPrivateKey: Data(edited.utf8))
            XCTAssertEqual(derived, publicPart(actual.publicKeyLine))
            XCTAssertNotEqual(derived, publicPart(decoy.publicKeyLine))
        } catch { /* Rejecting a mismatched container is also safe. */ }
    }

    func testPublicKeyRejectsInvalidAndTruncatedPrivateKeys() {
        for value in ["", "ssh-ed25519 AAAA public-only", "not a private key",
                      "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"] {
            XCTAssertThrowsError(try CitadelSession.publicKeyLine(fromPrivateKey: Data(value.utf8)))
        }
    }

    func testRSAPublicKeyMatchesOpenSSHOracle() throws {
        try withOpenSSHKey(type: "rsa", passphrase: "") { privateKey, expected in
            XCTAssertEqual(try CitadelSession.publicKeyLine(fromPrivateKey: privateKey), expected)
        }
    }

    func testEncryptedKeyDoesNotFallBackToItsPublicHeader() throws {
        try withOpenSSHKey(type: "ed25519", passphrase: "test-passphrase") { privateKey, expected in
            XCTAssertThrowsError(try CitadelSession.publicKeyLine(fromPrivateKey: privateKey))
            XCTAssertThrowsError(try CitadelSession.publicKeyLine(fromPrivateKey: privateKey, passphrase: "incorrect"))
            XCTAssertEqual(try CitadelSession.publicKeyLine(fromPrivateKey: privateKey,
                                                            passphrase: "test-passphrase"), expected)
        }
    }

    func testHostValidationDoesNotSucceedBeforeAsyncApproval() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let entered = expectation(description: "verifier entered")
        let notCompleted = expectation(description: "must wait for approval")
        notCompleted.isInverted = true
        let gate = ApprovalGate()
        let captured = expectation(description: "host fingerprint captured")
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let validator = HostKeyCapturingValidator(onCapture: { fingerprint in
            XCTAssertEqual(fingerprint.keyType, "ssh-ed25519")
            XCTAssertEqual(fingerprint.sha256Hex.count, 64)
            captured.fulfill()
        }, verifier: { _ in
            entered.fulfill()
            await gate.wait()
        })
        let promise = group.next().makePromise(of: Void.self)
        promise.futureResult.whenComplete { _ in notCompleted.fulfill() }
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        await fulfillment(of: [entered, captured], timeout: 2)
        await fulfillment(of: [notCompleted], timeout: 0.1)
        await gate.release()
        try await promise.futureResult.get()
    }

    func testRejectedHostFailsValidationPromise() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let validator = HostKeyCapturingValidator(onCapture: { _ in }, verifier: { _ in
            throw ApprovalError.rejected
        })
        let promise = group.next().makePromise(of: Void.self)
        validator.validateHostKey(hostKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey,
                                  validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
            XCTFail("Rejected host must not pass SSH authentication")
        } catch {
            XCTAssertTrue(error is ApprovalError)
        }
    }

    func testCancelledHostValidationCannotLaterAcceptTheHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let entered = expectation(description: "verifier entered")
        let gate = ApprovalGate()
        let validator = HostKeyCapturingValidator(onCapture: { _ in }, verifier: { _ in
            entered.fulfill()
            await gate.wait()
        })
        let promise = group.next().makePromise(of: Void.self)
        validator.validateHostKey(hostKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey,
                                  validationCompletePromise: promise)
        await fulfillment(of: [entered], timeout: 2)
        validator.cancelPendingValidation()
        do {
            try await promise.futureResult.get()
            XCTFail("Cancellation must fail the pending promise")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await gate.release()
    }

    func testValidationCompletionCanSynchronouslyCancelWithoutDeadlocking() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let validator = HostKeyCapturingValidator(onCapture: { _ in }, verifier: nil)
        let promise = group.next().makePromise(of: Void.self)
        let callbackCompleted = expectation(description: "completion callback reentered cancellation")
        promise.futureResult.whenSuccess {
            validator.cancelPendingValidation()
            callbackCompleted.fulfill()
        }
        validator.validateHostKey(
            hostKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey,
            validationCompletePromise: promise
        )
        await fulfillment(of: [callbackCompleted], timeout: 2)
        try await promise.futureResult.get()
    }

    func testConcurrentCancellationCannotReturnBeforeALaterSuccess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey

        for _ in 0..<250 {
            let gate = ApprovalGate()
            let observed = ValidationCompletionObservation()
            let validator = HostKeyCapturingValidator(onCapture: { _ in }, verifier: { _ in
                await gate.wait()
            })
            let promise = group.next().makePromise(of: Void.self)
            promise.futureResult.whenSuccess { observed.recordSuccess() }
            validator.validateHostKey(hostKey: key, validationCompletePromise: promise)

            async let release: Void = gate.release()
            let successBeforeCancellationReturned = await Task.detached {
                validator.cancelPendingValidation()
                return observed.hasSucceeded
            }.value
            await release

            do {
                try await promise.futureResult.get()
                XCTAssertTrue(successBeforeCancellationReturned,
                              "A pending validation must not succeed after cancellation returns")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    private func publicPart(_ key: String) -> String {
        key.split(whereSeparator: { $0.isWhitespace }).prefix(2).joined(separator: " ")
    }

    private func withOpenSSHKey(type: String, passphrase: String,
                               body: (Data, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-registration-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyPath = directory.appendingPathComponent("test_key")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", type, "-N", passphrase, "-C", "registration-test", "-f", keyPath.path]
        if type == "rsa" { process.arguments! += ["-b", "2048"] }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Could not generate isolated OpenSSH test key")
        let publicLine = try String(contentsOf: keyPath.appendingPathExtension("pub"), encoding: .utf8)
        try body(Data(contentsOf: keyPath), publicPart(publicLine))
    }
}

private enum ApprovalError: Error { case rejected }

private final class ValidationCompletionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false

    var hasSucceeded: Bool { lock.withLock { succeeded } }
    func recordSuccess() { lock.withLock { succeeded = true } }
}

private actor ApprovalGate {
    private var isReleased = false
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        isReleased = true
        waiting?.resume()
        waiting = nil
    }
}
#endif
