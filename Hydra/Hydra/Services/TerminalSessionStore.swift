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
    @Published var activeSessionId: String?

    private let sessionFactory: (Device) -> SSHSession

    init(sessionFactory: @escaping (Device) -> SSHSession = { _ in TerminalSessionStore.defaultBackend() }) {
        self.sessionFactory = sessionFactory
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
    }

    func closeAll() {
        for s in sessions { s.close() }
        sessions.removeAll()
        activeSessionId = nil
    }
}
