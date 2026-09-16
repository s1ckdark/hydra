#if DEBUG
import Foundation
import CryptoKit
import SSHTransport

extension SSHKeyRegistrationViewModel {
    /// Isolated UI acceptance fixture: never reads saved keys or contacts a server.
    static func uiTestFixture() -> SSHKeyRegistrationViewModel {
        let key = SSHKeyGenerator.generate(comment: "hydra-ui-test-only")
        let parts = key.publicKeyLine.split(separator: " ")
        let publicBytes = Data(base64Encoded: String(parts[1]))!
        let hostKey = HostKeyFingerprint(keyType: String(parts[0]), publicKeyBase64: String(parts[1]),
            sha256Hex: SHA256.hash(data: publicBytes).map { String(format: "%02x", $0) }.joined())
        return SSHKeyRegistrationViewModel(initialUsername: "fixture",
            keyProvider: { Data(key.privateKeyOpenSSH.utf8) },
            service: SSHRegistrationUITestService(hostKey: hostKey), devicesProvider: { [] })
    }
}

@MainActor
private final class SSHRegistrationUITestService: SSHKeyRegistering {
    let hostKey: HostKeyFingerprint
    init(hostKey: HostKeyFingerprint) { self.hostKey = hostKey }

    func register(target: SSHKeyRegistrationTarget, privateKey: Data, password: String,
                  approveHost: @escaping @MainActor (HostKeyFingerprint) async -> Bool,
                  onProgress: @escaping @MainActor (SSHKeyRegistrationProgress) -> Void) async throws -> SSHKeyRegistrationResult {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.arguments.contains("--ssh-registration-error-fixture") {
            throw SSHKeyRegistrationError.connectionFailed(.passwordAuthenticationUnsupported)
        }
        onProgress(.awaitingHostApproval)
        guard await approveHost(hostKey) else { throw SSHKeyRegistrationError.hostRejected }
        try Task.checkCancellation()
        onProgress(.verifying)
        return .init(alreadyRegistered: false)
    }

    func cancel() {}
}
#endif
