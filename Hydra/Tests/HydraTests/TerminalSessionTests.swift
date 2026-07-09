#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

@MainActor
final class TerminalSessionTests: XCTestCase {
    private func device(_ id: String) -> Device {
        Device(id: id, name: id, hostname: id, ipAddresses: [], tailscaleIp: "100.0.0.1",
               os: "Linux", status: "online", isExternal: false, tags: nil, user: "dave",
               lastSeen: Date(), sshEnabled: true, hasGpu: true, gpuModel: "RTX", gpuCount: 1)
    }

    /// Per-test temp known_hosts path so tests never touch the real ~/.ssh/known_hosts.
    private func tempKnownHostsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-known-hosts-\(UUID().uuidString)")
    }

    func testStoreOpenReusesSessionForSameDevice() {
        let store = TerminalSessionStore(sessionFactory: { _ in FakeSSHSession() })
        store.open(device: device("gpu1"))
        store.open(device: device("gpu1"))
        XCTAssertEqual(store.sessions.count, 1)      // 중복 생성 안 함
        store.open(device: device("gpu2"))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.activeSessionId, store.sessions.last?.id)
    }

    func testCloseAllDisconnects() {
        let store = TerminalSessionStore(sessionFactory: { _ in FakeSSHSession() })
        store.open(device: device("gpu1"))
        store.closeAll()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testConnectReachesConnectedAndStreamsOutput() async {
        let khURL = tempKnownHostsURL()
        defer { try? FileManager.default.removeItem(at: khURL) }
        let session = TerminalSession(device: device("gpu1"), sessionFactory: { FakeSSHSession() }, knownHostsURL: khURL)
        var got = Data()
        session.onOutput = { got.append($0) }
        await session.connect(cols: 80, rows: 24)
        // Fake는 connect→.connected, openShell→"fake$ " 출력. 단, 첫 연결은
        // 호스트키 미지(TOFU) 경로라 openShell 보류될 수 있음 → trustPendingHostKey 후 진행.
        if case .needsTrust = session.hostKeyPrompt { await session.trustPendingHostKey() }
        // 출력 스트림이 흐르는지(약간 대기)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(String(data: got, encoding: .utf8)?.contains("fake$") ?? false)
    }

    func testBlockedReasonSurvives() async {
        let khURL = tempKnownHostsURL()
        defer { try? FileManager.default.removeItem(at: khURL) }
        let store = KnownHostsStore(fileURL: khURL)
        // Pre-seed a DIFFERENT key for host "100.0.0.1" than the Fake's "AAAAFAKE",
        // so HostKeyGate.evaluate() returns .blocked (mismatch) once connect() reaches the gate.
        try? store.trust(KnownHostsEntry(hostPattern: "100.0.0.1", keyType: "ssh-ed25519", publicKey: "AAAADIFFERENT"))

        let session = TerminalSession(device: device("gpu1"), sessionFactory: { FakeSSHSession() }, knownHostsURL: khURL)
        await session.connect(cols: 80, rows: 24)
        // Give the state pump a brief moment in case a trailing nil-reason event
        // were (incorrectly) still able to land.
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard case .disconnected(let reason) = session.state else {
            XCTFail("expected .disconnected, got \(session.state)")
            return
        }
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("차단") ?? false)
    }

    func testReconnectAfterBlockedClearsLock() async {
        let khURL = tempKnownHostsURL()
        defer { try? FileManager.default.removeItem(at: khURL) }
        let store = KnownHostsStore(fileURL: khURL)
        // Pre-seed a DIFFERENT key for host "100.0.0.1" so first connect → .blocked
        try? store.trust(KnownHostsEntry(hostPattern: "100.0.0.1", keyType: "ssh-ed25519", publicKey: "AAAADIFFERENT"))

        let session = TerminalSession(device: device("gpu1"), sessionFactory: { FakeSSHSession() }, knownHostsURL: khURL)
        // First connect: blocked due to key mismatch (lock set to true)
        await session.connect(cols: 80, rows: 24)
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard case .disconnected(let reason) = session.state else {
            XCTFail("expected blocked state, got \(session.state)")
            return
        }
        XCTAssertTrue(reason?.contains("차단") ?? false)

        // Overwrite temp known_hosts to EMPTY so re-check returns .unknown (TOFU path)
        try? "".write(to: khURL, atomically: true, encoding: .utf8)

        // Second connect on SAME session: lock should be cleared and pump should run
        await session.connect(cols: 80, rows: 24)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // If lock was NOT cleared, state would remain frozen at blocked.
        // If lock WAS cleared, the pump runs and the flow reaches the .unknown TOFU gate,
        // setting hostKeyPrompt to .needsTrust(...) — proof the lock was reset.
        if case .needsTrust = session.hostKeyPrompt {
            // Success: lock was cleared and fresh flow reached the TOFU path
            return
        }
        XCTFail("expected hostKeyPrompt to be .needsTrust after reconnect (lock should have been cleared), got \(String(describing: session.hostKeyPrompt))")
    }

    /// LOCAL TEST (I1): a disconnected SSHSession's AsyncStreams are permanently finished,
    /// so reconnecting must mint a FRESH session (via sessionFactory) rather than reusing
    /// the dead one — otherwise reconnect would yield a blank terminal (no new output).
    func testReconnectAfterDisconnectStreamsOutput() async {
        let khURL = tempKnownHostsURL()
        defer { try? FileManager.default.removeItem(at: khURL) }
        let session = TerminalSession(device: device("gpu1"), sessionFactory: { FakeSSHSession() }, knownHostsURL: khURL)
        var got = Data()
        session.onOutput = { got.append($0) }

        await session.connect(cols: 80, rows: 24)
        if case .needsTrust = session.hostKeyPrompt { await session.trustPendingHostKey() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(String(data: got, encoding: .utf8)?.contains("fake$") ?? false)

        // Disconnect (simulating the remote shell closing / user disconnecting).
        session.close()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Reconnect on the SAME TerminalSession instance. Host key is already trusted from
        // the first connect, so this should sail through HostKeyGate without a new prompt.
        got = Data()
        await session.connect(cols: 80, rows: 24)
        if case .needsTrust = session.hostKeyPrompt { await session.trustPendingHostKey() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(
            String(data: got, encoding: .utf8)?.contains("fake$") ?? false,
            "expected fresh output after reconnect — a dead reused session would yield a blank terminal"
        )
    }
}
#endif
