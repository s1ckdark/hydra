import Foundation
import SSHTransport
import KnownHosts

struct ResolvedKey: Equatable {
    let path: String
    let pem: Data
    let algorithm: String
}

struct SSHCredentials {
    let user: String
    let port: Int
    let keys: [ResolvedKey]   // OpenSSH-style ordered offer list
}

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

    /// LOCAL FIX (I1): a factory rather than a fixed instance — `SSHSession`'s AsyncStreams
    /// are finished (permanently dead) once `disconnect()` runs, so reconnecting must build
    /// a brand-new session rather than resuming the old one.
    private let sessionFactory: () -> SSHSession
    private let credentialResolver: () -> SSHCredentials
    private var session: SSHSession
    private let knownHosts: KnownHostsStore
    private var pumpTask: Task<Void, Never>?
    private var statePumpTask: Task<Void, Never>?
    private var pendingShell: (cols: Int, rows: Int)?
    /// LOCAL FIX (I2): the init-time `session` is minted but never actually dialed —
    /// the multi-key loop below offers each key on a session of its own via `sessionFactory()`.
    /// Without this flag, the loop would mint a SECOND (redundant) session for the very
    /// first key attempt and immediately disconnect the init-time one, which — because
    /// `SSHSession.disconnect()` yields a trailing `.disconnected` event into the same
    /// AsyncStream it's about to be reused on — would corrupt state if that same object
    /// were ever reused afterward. So the first-ever key attempt on a fresh `TerminalSession`
    /// reuses the pristine init-time session as-is (no redundant mint, no premature disconnect);
    /// every attempt after that (fallback keys, or any later reconnect) always mints fresh.
    private var hasAttemptedConnect = false
    /// Set right before we assign an intentional terminal `.disconnected(reason:)`.
    /// `session.disconnect()` always yields a trailing `.disconnected(reason: nil)` into
    /// the state stream; since that value (or an in-flight `.connected`) may already be
    /// buffered in the AsyncStream when we cancel `statePumpTask`, cancellation alone does
    /// not reliably stop it from draining through. This flag is checked from the pump body
    /// on the same MainActor turn it's set, so it deterministically blocks the stale value
    /// from clobbering the reason we just set — cancelling the task is still done for cleanup,
    /// but this flag is what actually preserves the reason.
    private var isTerminalStateLocked = false

    init(device: Device,
         sessionFactory: @escaping () -> SSHSession,
         knownHostsURL: URL? = nil,
         credentialResolver: @escaping () -> SSHCredentials = TerminalSession.defaultCredentials) {
        self.id = device.id
        self.deviceId = device.id
        self.deviceName = device.displayName
        self.host = device.tailscaleIp
        self.sessionFactory = sessionFactory
        self.credentialResolver = credentialResolver
        self.session = sessionFactory()
        #if os(macOS)
        let defaultKHURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        #else
        // homeDirectoryForCurrentUser is unavailable on iOS; NSHomeDirectory()
        // is the cross-platform equivalent (app sandbox home on iOS).
        let defaultKHURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh/known_hosts")
        #endif
        let khURL = knownHostsURL ?? defaultKHURL
        self.knownHosts = KnownHostsStore(fileURL: khURL)
    }

    func connect(cols: Int, rows: Int) async {
        isTerminalStateLocked = false
        pumpTask?.cancel()
        statePumpTask?.cancel()
        // See LOCAL FIX (I2): only disconnect the current session if it was already put
        // to use by a previous attempt — the very first attempt on a fresh instance reuses
        // the untouched init-time session, so there is nothing to disconnect yet.
        if hasAttemptedConnect { session.disconnect() }
        pendingShell = (cols, rows)

        let creds = credentialResolver()
        guard !creds.keys.isEmpty else {
            state = .disconnected(reason: "SSH 개인키를 찾을 수 없습니다. ~/.ssh 에 키를 만들어주세요.")
            return
        }

        state = .connecting
        var lastAuthError: String?

        // OpenSSH-style: offer each key in order until one authenticates.
        for key in creds.keys {
            let s: SSHSession = hasAttemptedConnect ? sessionFactory() : session
            self.session = s
            hasAttemptedConnect = true
            do {
                try await s.connect(host: host, port: creds.port, user: creds.user,
                                    auth: .privateKey(key.pem, passphrase: nil))
            } catch let e as SSHError {
                if case .authFailed(let m) = e {
                    lastAuthError = m
                    s.disconnect()
                    continue                      // 다음 키로 폴백
                }
                state = .disconnected(reason: describe(e))   // unreachable/handshake 등 즉시 실패
                return
            } catch {
                state = .disconnected(reason: "\(error)")
                return
            }
            // 인증 성공 세션에 대해서만 호스트키 TOFU 판정
            switch HostKeyGate.evaluate(host: host, fingerprint: s.remoteHostKey, store: knownHosts) {
            case .proceed:
                startStatePump()
                await openShellNow()
                return
            case .needsTrust(let sha):
                startStatePump()
                hostKeyPrompt = .needsTrust(sha256: sha)
                return
            case .blocked:
                isTerminalStateLocked = true
                state = .disconnected(reason: "호스트키 불일치 — 연결 차단")
                s.disconnect()
                return
            }
        }

        // 모든 키 실패. NOTE: the libssh2 backend collapses TCP-refused / host-down /
        // handshake failures into SSHError.authFailed, so this path is reached for an
        // OFFLINE host too — not just genuine auth rejection. We therefore surface the
        // raw reason and phrase the message to cover both ("거부 또는 도달 실패") instead of
        // only telling the user to register keys against a host that may simply be down.
        if let m = lastAuthError { NSLog("[terminal] all offered keys rejected; last: \(m)") }
        let algos = creds.keys.map(\.algorithm).joined(separator: ", ")
        let detail = lastAuthError.map { " (사유: \($0))" } ?? ""
        state = .disconnected(reason:
            "연결 실패 — 제시한 키(\(algos))가 \(host)에서 거부되었거나 호스트에 도달하지 못했습니다\(detail). "
            + "호스트가 온라인인지 확인하고, 키가 등록돼 있지 않다면 ssh-copy-id로 공개키를 등록하세요.")
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
        isTerminalStateLocked = true
        state = .disconnected(reason: "호스트키 신뢰 취소")
        statePumpTask?.cancel()
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
    func close() {
        pumpTask?.cancel()
        statePumpTask?.cancel()
        session.disconnect()
        // I2 hardening: a close() before the first connect() disconnects the pristine
        // init-time session; mark it "used" so a later connect() mints a FRESH session
        // (line 99) instead of reusing this now-dead one (finished AsyncStreams → blank
        // terminal, the I1 bug). Idempotent for the normal post-connect close path.
        hasAttemptedConnect = true
    }

    private func startStatePump() {
        statePumpTask = Task { [weak self] in
            guard let self else { return }
            for await st in self.session.state {
                guard !self.isTerminalStateLocked else { continue }
                self.state = st
            }
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

    /// Default credential resolution: config.yaml (user/port + its key first),
    /// then `~/.ssh` keys in OpenSSH preference order, deduped by absolute path.
    static func defaultCredentials() -> SSHCredentials {
        #if os(macOS)
        let user: String
        let port: Int
        var paths: [String] = []
        if let r = ClusterSSHConfig.load() {
            user = r.user; port = r.port
            paths.append(r.privateKeyPath)
        } else {
            user = NSUserName(); port = 22
        }
        if let pairs = try? SSHKeyLocator.orderedKeyPairs() {
            for kp in pairs where !paths.contains(kp.privatePath) {
                paths.append(kp.privatePath)
            }
        }
        let keys: [ResolvedKey] = paths.compactMap { p in
            guard let pem = FileManager.default.contents(atPath: p) else { return nil }
            let base = (p as NSString).lastPathComponent
            return ResolvedKey(path: p, pem: pem,
                               algorithm: SSHKeyLocator.algorithmName(forBasename: base))
        }
        return SSHCredentials(user: user, port: port, keys: keys)
        #else
        // ── iOS: 임포트한 키(Keychain) + 설정 username ──
        let pem = CredentialStore.shared.get(.sshPrivateKeyPEM)
        let user = UserDefaults.standard.string(forKey: "sshUsername") ?? "root"
        return makeImportedCredentials(pem: pem, user: user, port: 22)
        #endif
    }

    /// Builds credentials from a single imported private key (iOS path). Pure and
    /// platform-agnostic so it is unit-testable on macOS.
    nonisolated static func makeImportedCredentials(pem: String, user: String, port: Int) -> SSHCredentials {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SSHCredentials(user: user, port: port, keys: []) }
        return SSHCredentials(user: user, port: port,
                              keys: [ResolvedKey(path: "keychain", pem: Data(trimmed.utf8), algorithm: "imported")])
    }
}
