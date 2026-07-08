#if os(macOS)
import Foundation
import SSHTransport
import KnownHosts

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: String
    let deviceId: String
    let deviceName: String
    let host: String

    @Published var state: SSHState = .idle
    /// TOFU: set when the host key is unknown and awaiting user trust.
    @Published var hostKeyPrompt: HostKeyDecision?

    /// The view subscribes to feed bytes into SwiftTerm.
    var onOutput: ((Data) -> Void)?

    private let session: SSHSession
    private let knownHosts: KnownHostsStore
    private var pumpTask: Task<Void, Never>?
    private var pendingShell: (cols: Int, rows: Int)?

    init(device: Device, session: SSHSession) {
        self.id = device.id
        self.deviceId = device.id
        self.deviceName = device.displayName
        self.host = device.tailscaleIp
        self.session = session
        let khURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        self.knownHosts = KnownHostsStore(fileURL: khURL)
    }

    func connect(cols: Int, rows: Int) async {
        pendingShell = (cols, rows)
        // Resolve credentials: config.yaml → SSHKeyLocator fallback.
        let user: String
        let keyPath: String
        let port: Int
        if let r = ClusterSSHConfig.load() {
            user = r.user; keyPath = r.privateKeyPath; port = r.port
        } else {
            user = NSUserName()
            keyPath = (try? SSHKeyLocator.defaultPrivateKeyPath()) ?? ""
            port = 22
        }
        guard let pem = FileManager.default.contents(atPath: keyPath) else {
            state = .disconnected(reason: "개인키를 읽을 수 없습니다: \(keyPath)")
            return
        }
        startStatePump()
        do {
            try await session.connect(host: host, port: port, user: user,
                                      auth: .privateKey(pem, passphrase: nil))
        } catch {
            state = .disconnected(reason: (error as? SSHError).map(describe) ?? "\(error)")
            return
        }
        // Host-key TOFU gate (Citadel transport already acceptAnything).
        switch HostKeyGate.evaluate(host: host, fingerprint: session.remoteHostKey, store: knownHosts) {
        case .proceed:
            await openShellNow()
        case .needsTrust(let sha):
            hostKeyPrompt = .needsTrust(sha256: sha)   // 뷰가 시트로 물음
        case .blocked:
            state = .disconnected(reason: "호스트키 불일치 — 연결 차단")
            session.disconnect()
        }
    }

    /// Called by the TOFU sheet's "Trust" action.
    func trustPendingHostKey() async {
        guard let fp = session.remoteHostKey else { return }
        try? knownHosts.trust(HostKeyGate.entry(host: host, fingerprint: fp))
        hostKeyPrompt = nil
        await openShellNow()
    }

    func cancelPendingHostKey() {
        hostKeyPrompt = nil
        state = .disconnected(reason: "호스트키 신뢰 취소")
        session.disconnect()
    }

    private func openShellNow() async {
        guard let s = pendingShell else { return }
        startOutputPump()
        do { try await session.openShell(termType: "xterm-256color", cols: s.cols, rows: s.rows) }
        catch { state = .disconnected(reason: "셸 열기 실패: \(error)") }
    }

    func send(_ data: Data) { Task { try? await session.write(data) } }
    func resize(cols: Int, rows: Int) { Task { try? await session.resize(cols: cols, rows: rows) } }
    func close() { pumpTask?.cancel(); session.disconnect() }

    private func startStatePump() {
        Task { [weak self] in
            guard let self else { return }
            for await st in self.session.state { self.state = st }
        }
    }
    private func startOutputPump() {
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.session.output { self.onOutput?(chunk) }
        }
    }

    private func describe(_ e: SSHError) -> String {
        switch e {
        case .unreachable(let m): return "도달 불가: \(m)"
        case .handshakeFailed(let m): return "핸드셰이크 실패: \(m)"
        case .authFailed(let m): return "인증 실패: \(m)"
        case .channelFailed(let m): return "채널 실패: \(m)"
        case .disconnected: return "연결 끊김"
        }
    }
}
#endif
