import XCTest
import SSHTransport
@testable import Hydra

@MainActor
final class TerminalKeyRecoveryTests: XCTestCase {
    func testMissingKeyFailureKeepsActualAttemptTargetAcrossSettingsChanges() async {
        var user = "original-user"
        let backend = RecoveryBackend()
        let session = TerminalSession(device: device(), sessionFactory: { backend }, credentialResolver: {
            SSHCredentials(user: user, port: 2222, keys: [])
        })
        defer { session.close() }
        await session.connect(cols: 80, rows: 24)
        user = "changed-user"
        let target = SSHKeyRegistrationTarget(host: "100.64.0.77", user: "original-user", port: 2222)
        XCTAssertEqual(session.connectionTarget, target)
        let failure = session.state
        XCTAssertEqual(session.prepareKeyRegistration(), target)
        XCTAssertEqual(session.state, failure, "The original failure must remain visible after retiring the backend")
        XCTAssertEqual(backend.disconnects, 1)
        session.send(Data("must-not-send".utf8))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.writes, 0)
        await session.connect(cols: 80, rows: 24)
        XCTAssertEqual(session.connectionTarget?.user, "changed-user")
    }

    func testRecoveryIsUnavailableBeforeAnAttemptOrAfterCleanDisconnect() async {
        let session = TerminalSession(device: device(), sessionFactory: { RecoveryBackend() }, credentialResolver: {
            SSHCredentials(user: "fixture", port: 22, keys: [])
        })
        XCTAssertNil(session.prepareKeyRegistration())
        await session.connect(cols: 80, rows: 24)
        session.close()
        XCTAssertNil(session.prepareKeyRegistration())
        session.state = .connected
        XCTAssertNil(session.prepareKeyRegistration())
    }

    private func device() -> Device {
        Device(id: "recovery-fixture", name: "fixture.tail.test", hostname: "fixture-machine", ipAddresses: [],
               tailscaleIp: "100.64.0.77", os: "macOS", status: "online", isExternal: false, tags: nil,
               user: "not-the-ssh-account", lastSeen: Date(), sshEnabled: true, hasGpu: false, gpuModel: nil, gpuCount: 0)
    }
}

private final class RecoveryBackend: SSHSession {
    let output = AsyncStream<Data> { $0.finish() }
    let state = AsyncStream<SSHState> { $0.finish() }
    let remoteHostKey: HostKeyFingerprint? = nil
    var disconnects = 0
    var writes = 0
    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {}
    func openShell(termType: String, cols: Int, rows: Int) async throws {}
    func write(_ data: Data) async throws { writes += 1 }
    func resize(cols: Int, rows: Int) async throws {}
    func disconnect() { disconnects += 1 }
}
