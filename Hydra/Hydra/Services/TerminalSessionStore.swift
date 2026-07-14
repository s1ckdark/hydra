import Foundation
import SSHTransport
#if os(macOS)
import SSHTransportMac
#endif
import SSHTransportCitadel

@MainActor
final class TerminalSessionStore: ObservableObject {
    static let shared = TerminalSessionStore()

    @Published var sessions: [TerminalSession] = []
    @Published var activeSessionId: String? {
        didSet { persistOpenSessions() }
    }

    private let sessionFactory: (Device) -> SSHSession
    private let defaults: UserDefaults
    private var hasRestored = false

    /// 세션 id == deviceId이므로 deviceId 목록만으로 복원할 수 있다.
    /// 스펙: docs/superpowers/specs/2026-07-14-terminal-session-persistence-design.md
    static let openDeviceIdsKey = "terminal.openDeviceIds"
    static let activeDeviceIdKey = "terminal.activeDeviceId"

    init(sessionFactory: @escaping (Device) -> SSHSession = { _ in TerminalSessionStore.defaultBackend() },
         defaults: UserDefaults = .standard) {
        self.sessionFactory = sessionFactory
        self.defaults = defaults
    }

    /// libssh2 by default on macOS (rsa-sha2 + every key); `HYDRA_SSH_BACKEND=citadel`
    /// selects the pure-Swift Citadel backend there. iOS has no libssh2, so it always
    /// uses Citadel.
    ///
    /// `nonisolated`: this store is `@MainActor`, but `defaultBackend()` is called from
    /// the plain (non-isolated) `sessionFactory` closure type in `init`'s default arg,
    /// and from synchronous XCTest methods. It only reads the environment and constructs
    /// a backend, touching no main-actor state — do NOT drop this annotation.
    nonisolated static func defaultBackend() -> SSHSession {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["HYDRA_SSH_BACKEND"]?.lowercased() == "citadel" {
            return CitadelSession()
        }
        return LibSSH2Session()
        #else
        return CitadelSession()
        #endif
    }

    func open(device: Device) {
        if let existing = sessions.first(where: { $0.deviceId == device.id }) {
            activeSessionId = existing.id       // 중복 생성 금지 — 포커스만
            return
        }
        // LOCAL FIX (I1): pass a per-device factory (not a fixed instance) so TerminalSession
        // can mint a fresh SSHSession on every connect()/reconnect() rather than reusing one
        // whose AsyncStreams are already finished after a prior disconnect().
        let s = TerminalSession(device: device, sessionFactory: { [sessionFactory] in sessionFactory(device) })
        sessions.append(s)
        activeSessionId = s.id
    }

    func close(id: String) {
        sessions.first(where: { $0.id == id })?.close()
        sessions.removeAll { $0.id == id }
        if activeSessionId == id { activeSessionId = sessions.last?.id }
        persistOpenSessions()
    }

    /// applicationWillTerminate 경로 — 저장 목록은 건드리지 않는다.
    /// 여기서 persist하면 앱을 종료할 때마다 복원 목록이 지워져 재시작 복원이
    /// 영원히 빈 목록이 된다. 사용자가 ✕로 닫는 close(id:)만 목록에서 제거.
    func closeAll() {
        for s in sessions { s.close() }
        sessions.removeAll()
        isPersistenceSuppressed = true
        activeSessionId = nil
        isPersistenceSuppressed = false
    }

    // MARK: - 재시작 복원

    private var isPersistenceSuppressed = false

    private func persistOpenSessions() {
        guard !isPersistenceSuppressed else { return }
        defaults.set(sessions.map(\.deviceId), forKey: Self.openDeviceIdsKey)
        defaults.set(activeSessionId, forKey: Self.activeDeviceIdKey)
    }

    /// 런치당 1회: 지난 실행에서 열려 있던 세션을 현재 디바이스 목록과 대조해
    /// 재생성한다. 목록에 없는 deviceId는 버린다(디바이스 소멸). 세션은 idle로
    /// 만들어지고 pane 표시 시점에 lazy 연결되므로 연결 폭주는 없다.
    func restoreIfNeeded(devices: [Device]) {
        guard !hasRestored, sessions.isEmpty else { hasRestored = true; return }
        let savedIds = defaults.stringArray(forKey: Self.openDeviceIdsKey) ?? []
        let savedActive = defaults.string(forKey: Self.activeDeviceIdKey)
        guard !savedIds.isEmpty else { hasRestored = true; return }
        // 디바이스 목록이 아직 비어 있으면(오프라인/백엔드 미기동 런치) 여기서
        // 진행하면 안 된다 — 아무것도 매칭되지 않아 저장 목록이 빈 배열로 덮여
        // 영구 소실된다. 래치도 걸지 않고 다음 호출에서 재시도한다.
        guard !devices.isEmpty else { return }
        hasRestored = true
        for id in savedIds {
            if let device = devices.first(where: { $0.id == id }) {
                open(device: device)
            }
        }
        if let savedActive, sessions.contains(where: { $0.id == savedActive }) {
            activeSessionId = savedActive
        }
        persistOpenSessions()   // 소멸 디바이스가 걸러진 최종 상태로 갱신
    }
}
