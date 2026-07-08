#if os(macOS)
import Foundation
import SSHTransport
import SSHTransportCitadel

@MainActor
final class TerminalSessionStore: ObservableObject {
    static let shared = TerminalSessionStore()

    @Published var sessions: [TerminalSession] = []
    @Published var activeSessionId: String?

    private let sessionFactory: (Device) -> SSHSession

    init(sessionFactory: @escaping (Device) -> SSHSession = { _ in CitadelSession() }) {
        self.sessionFactory = sessionFactory
    }

    func open(device: Device) {
        if let existing = sessions.first(where: { $0.deviceId == device.id }) {
            activeSessionId = existing.id       // 중복 생성 금지 — 포커스만
            return
        }
        let s = TerminalSession(device: device, session: sessionFactory(device))
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
#endif
