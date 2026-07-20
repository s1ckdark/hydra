#if os(macOS)
import XCTest
import SSHTransport
@testable import Hydra

/// 세션 저장(목록 복원 + tmux 지속) 검증 —
/// 스펙: docs/superpowers/specs/2026-07-14-terminal-session-persistence-design.md
@MainActor
final class TerminalSessionPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "hydra-persistence-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func device(_ id: String) -> Device {
        Device(id: id, name: id, hostname: id, ipAddresses: [], tailscaleIp: "100.0.0.1",
               os: "Linux", status: "online", isExternal: false, tags: nil, user: "dave",
               lastSeen: Date(), sshEnabled: true, hasGpu: false, gpuModel: nil, gpuCount: 0)
    }

    private func makeStore() -> TerminalSessionStore {
        TerminalSessionStore(sessionFactory: { _ in FakeSSHSession() }, defaults: defaults)
    }

    // MARK: - 저장

    func testOpenPersistsDeviceIdsAndActive() {
        let store = makeStore()
        store.open(device: device("a"))
        store.open(device: device("b"))
        XCTAssertEqual(defaults.stringArray(forKey: TerminalSessionStore.openDeviceIdsKey), ["a", "b"])
        XCTAssertEqual(defaults.string(forKey: TerminalSessionStore.activeDeviceIdKey), "b")
    }

    func testClosePersistsRemoval() {
        let store = makeStore()
        store.open(device: device("a"))
        store.open(device: device("b"))
        store.close(id: "b")
        XCTAssertEqual(defaults.stringArray(forKey: TerminalSessionStore.openDeviceIdsKey), ["a"])
        XCTAssertEqual(defaults.string(forKey: TerminalSessionStore.activeDeviceIdKey), "a")
    }

    /// applicationWillTerminate 시나리오: closeAll()은 저장 목록을 지우면 안 된다 —
    /// 지우면 앱을 종료할 때마다 복원 목록이 사라져 재시작 복원이 항상 빈 목록이 된다.
    func testCloseAllKeepsSavedList() {
        let store = makeStore()
        store.open(device: device("a"))
        store.open(device: device("b"))
        store.closeAll()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: TerminalSessionStore.openDeviceIdsKey), ["a", "b"])
        XCTAssertEqual(defaults.string(forKey: TerminalSessionStore.activeDeviceIdKey), "b")
    }

    // MARK: - 복원

    func testRestoreReopensInOrderAndRestoresActive() {
        defaults.set(["a", "b", "c"], forKey: TerminalSessionStore.openDeviceIdsKey)
        defaults.set("b", forKey: TerminalSessionStore.activeDeviceIdKey)

        let store = makeStore()
        store.restoreIfNeeded(devices: [device("c"), device("a"), device("b")])

        XCTAssertEqual(store.sessions.map(\.deviceId), ["a", "b", "c"])   // 저장 순서 유지
        XCTAssertEqual(store.activeSessionId, "b")
    }

    func testRestoreDropsVanishedDevices() {
        defaults.set(["gone", "a"], forKey: TerminalSessionStore.openDeviceIdsKey)
        defaults.set("gone", forKey: TerminalSessionStore.activeDeviceIdKey)

        let store = makeStore()
        store.restoreIfNeeded(devices: [device("a")])

        XCTAssertEqual(store.sessions.map(\.deviceId), ["a"])
        // 소멸 디바이스가 걸러진 최종 상태가 다시 저장된다.
        XCTAssertEqual(defaults.stringArray(forKey: TerminalSessionStore.openDeviceIdsKey), ["a"])
        // 활성이 소멸 디바이스였으면 마지막 open이 활성으로 남는다.
        XCTAssertEqual(store.activeSessionId, "a")
    }

    /// 회귀 (리뷰 HIGH): 오프라인/백엔드 미기동 런치에서 디바이스 목록이 비어 있을 때
    /// 복원이 진행되면 저장 목록이 빈 배열로 덮여 영구 소실된다. 빈 목록에서는
    /// 래치 없이 대기하고, 목록이 도착한 다음 호출에서 복원해야 한다.
    func testRestoreWaitsForDeviceListInsteadOfWiping() {
        defaults.set(["a"], forKey: TerminalSessionStore.openDeviceIdsKey)
        defaults.set("a", forKey: TerminalSessionStore.activeDeviceIdKey)

        let store = makeStore()
        store.restoreIfNeeded(devices: [])   // 아직 로드 전

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: TerminalSessionStore.openDeviceIdsKey), ["a"])

        store.restoreIfNeeded(devices: [device("a")])   // 목록 도착 후 재시도
        XCTAssertEqual(store.sessions.map(\.deviceId), ["a"])
        XCTAssertEqual(store.activeSessionId, "a")
    }

    func testRestoreRunsOncePerLaunch() {
        defaults.set(["a"], forKey: TerminalSessionStore.openDeviceIdsKey)
        let store = makeStore()
        store.restoreIfNeeded(devices: [device("a")])
        store.restoreIfNeeded(devices: [device("a")])
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testRestoreSkippedWhenSessionAlreadyOpen() {
        defaults.set(["a", "b"], forKey: TerminalSessionStore.openDeviceIdsKey)
        let store = makeStore()
        // 복원 전에 사용자가 이미 세션을 연 경우 — 새 작업 세트를 존중하고 복원하지 않는다.
        store.open(device: device("c"))
        store.restoreIfNeeded(devices: [device("a"), device("b"), device("c")])
        XCTAssertEqual(store.sessions.map(\.deviceId), ["c"])
    }

    // MARK: - tmux 부트스트랩 주입

    private func tempKnownHostsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-known-hosts-\(UUID().uuidString)")
    }

    private func connectAndTrust(_ session: TerminalSession) async {
        await session.connect(cols: 80, rows: 24)
        if case .needsTrust = session.hostKeyPrompt { await session.trustPendingHostKey() }
    }

    func testTmuxLineWrittenWhenEnabled() async {
        let khURL = tempKnownHostsURL()
        defer { try? FileManager.default.removeItem(at: khURL) }
        let scripted = ScriptedSSHSession(.succeed(HostKeyFingerprint(
            keyType: "ssh-ed25519", publicKeyBase64: "AAAATEST", sha256Hex: "ab")))
        let session = TerminalSession(device: device("a"),
                                      sessionFactory: { scripted },
                                      knownHostsURL: khURL,
                                      credentialResolver: { .init(user: "dave", port: 22,
                                          keys: [ResolvedKey(path: "p", pem: Data("k".utf8), algorithm: "ed25519")]) },
                                      persistenceEnabled: { true })
        await connectAndTrust(session)
        XCTAssertTrue(scripted.openShellCalled)
        let writtenText = scripted.written.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(writtenText.contains("tmux new-session -A -s hydra"),
                      "expected tmux bootstrap, got: \(writtenText)")
    }

    func testNothingWrittenWhenDisabled() async {
        let khURL = tempKnownHostsURL()
        defer { try? FileManager.default.removeItem(at: khURL) }
        let scripted = ScriptedSSHSession(.succeed(HostKeyFingerprint(
            keyType: "ssh-ed25519", publicKeyBase64: "AAAATEST", sha256Hex: "ab")))
        let session = TerminalSession(device: device("a"),
                                      sessionFactory: { scripted },
                                      knownHostsURL: khURL,
                                      credentialResolver: { .init(user: "dave", port: 22,
                                          keys: [ResolvedKey(path: "p", pem: Data("k".utf8), algorithm: "ed25519")]) },
                                      persistenceEnabled: { false })
        await connectAndTrust(session)
        XCTAssertTrue(scripted.openShellCalled)
        XCTAssertTrue(scripted.written.isEmpty)
    }

    func testBootstrapLineExecsTmuxGuardedWithFallback() {
        let line = TerminalSession.tmuxBootstrapLine()
        XCTAssertTrue(line.contains("command -v tmux"))               // 존재 검사 선행
        XCTAssertTrue(line.contains("tmux new-session -A -s hydra"))
        // `exec tmux …`: 로그인 셸을 tmux로 대체해 접속=tmux가 되게 한다(사용자가 요청한
        // "루트 셸 위에서 tmux 명령 실행" 형태 제거). exec의 옛 우려(실패 시 채널 닫힘)는
        // `command -v tmux` 가드(&& 앞)로 tmux 부재 시 exec에 도달하지 않게 하고, 주입을
        // 프롬프트 안정 이후로 게이팅해 명령 전달을 보장하므로 안전하다.
        XCTAssertTrue(line.contains("&& exec tmux new-session"))
        XCTAssertTrue(line.contains("; clear"))                       // tmux 부재 폴백 시 화면 정리
        XCTAssertTrue(line.hasSuffix("\n"))
    }
}
#endif
