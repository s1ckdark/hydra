#if os(macOS)
import XCTest
import SSHTransport
@testable import Hydra

@MainActor
final class TerminalSessionTests: XCTestCase {
    private func device(_ id: String) -> Device {
        Device(id: id, name: id, hostname: id, ipAddresses: [], tailscaleIp: "100.0.0.1",
               os: "Linux", status: "online", isExternal: false, tags: nil, user: "dave",
               lastSeen: Date(), sshEnabled: true, hasGpu: true, gpuModel: "RTX", gpuCount: 1)
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
        let session = TerminalSession(device: device("gpu1"), session: FakeSSHSession())
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
}
#endif
