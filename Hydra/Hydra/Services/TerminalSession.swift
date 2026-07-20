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

    /// The view subscribes to feed bytes into SwiftTerm. Set in the
    /// representable's makeNSView. 뷰가 아직 안 붙었을 때(onOutput == nil) 도착한
    /// 출력은 아래 버퍼에 쌓았다가, 뷰가 붙는 순간(didSet) 한꺼번에 재생한다. 이게
    /// 없으면 tmux 없는 서버의 "한 번만 나오는 첫 프롬프트"가 훅업 전에 도착해 버려져
    /// 빈 화면으로 남는다(tmux는 이후 출력이 계속 나와 가려졌다).
    var onOutput: ((Data) -> Void)? {
        didSet {
            guard let onOutput, !outputBuffer.isEmpty else { return }
            let buffered = outputBuffer
            outputBuffer = Data()
            onOutput(buffered)
        }
    }
    private var outputBuffer = Data()

    /// 셸 출력이 마지막으로 도착한 시각과 "출력을 한 번이라도 봤는지" 플래그.
    /// tmux 부트스트랩을 셸이 프롬프트에서 idle 상태가 된 뒤에 주입하려고
    /// (openShellNow → injectBootstrapWhenReady) 출력 펌프가 매 청크마다 갱신한다.
    private var lastOutputAt: Date = .distantPast
    private var sawShellOutput = false

    /// 뷰(SwiftTerm)가 마지막으로 요청한 터미널 크기.
    ///
    /// connect()는 셸을 하드코딩 80×24로 열고(뷰 레이아웃 전이라 실제 크기를 모른다),
    /// 실제 크기는 이후 `sizeChanged`→`resize`가 채운다. 그런데 그 리사이즈가 openShell
    /// 완료 **전**에 도착하면 `LibSSH2Session.resize`의 `guard let shell`(아직 nil)에서
    /// 조용히 버려지고, 그 뒤로 뷰 크기가 안 바뀌면 다시 리사이즈가 오지 않아 tmux가
    /// 80×24로 생성돼 큰 페인의 좌상단 일부(≈1/6)만 그려진다. 이를 막으려고 마지막 요청
    /// 크기를 기억했다가 셸이 열리고 tmux exec 직전에 재적용한다(applyPendingSize).
    private var lastRequestedSize: (cols: Int, rows: Int)?

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

    /// tmux 세션 지속(opt-in) 여부. 주입 가능해야 유닛 테스트에서 UserDefaults 없이
    /// 켜고 끌 수 있다. 기본값은 설정 토글(terminalPersistViaTmux)을 읽는다.
    private let persistenceEnabled: () -> Bool

    init(device: Device,
         sessionFactory: @escaping () -> SSHSession,
         knownHostsURL: URL? = nil,
         credentialResolver: @escaping () -> SSHCredentials = TerminalSession.defaultCredentials,
         persistenceEnabled: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: "terminalPersistViaTmux")
         }) {
        self.persistenceEnabled = persistenceEnabled
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
            #if os(macOS)
            state = .disconnected(reason: "SSH 개인키를 찾을 수 없습니다. ~/.ssh 에 키를 만들어주세요.")
            #else
            state = .disconnected(reason: "SSH 개인키가 없습니다. 설정 → SSH 키에서 개인키를 임포트하세요.")
            #endif
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
        do {
            try await session.openShell(termType: "xterm-256color", cols: s.cols, rows: s.rows)
            if persistenceEnabled() {
                await injectBootstrapWhenReady()   // exec 직전 applyPendingSize 수행
            } else {
                await applyPendingSize()           // plain 셸도 실제 뷰 크기로 맞춘다
            }
            // Plain 셸(tmux 없음/off)의 첫 프롬프트가 뷰 훅업 전에 나와도 버려지지 않게
            // 하는 처리는 onOutput 버퍼링(위 onOutput.didSet)에서 담당한다.
        }
        catch { state = .disconnected(reason: "셸 열기 실패: \(error)") }
    }

    /// tmux 부트스트랩을 "셸이 프롬프트에서 idle 상태가 된 뒤"에 주입한다.
    ///
    /// 왜 필요한가: `openShell()`은 PTY와 셸을 요청하고 곧바로 반환할 뿐, 원격
    /// 로그인 셸(zsh)이 rc(.zshrc/oh-my-zsh/p10k/플러그인)를 다 실행하고 zle 라인
    /// 에디터를 띄워 입력을 받을 준비가 됐는지는 기다리지 않는다. rc 실행이 빠른
    /// 호스트(LAN, ~0.5s)에서는 즉시 주입해도 문제가 없지만, oh-my-zsh + 대형
    /// fastfetch 배너 + zsh-syntax-highlighting/autosuggestions 같은 무거운 zle
    /// 훅을 로드하느라 rc가 1~4초 걸리는 호스트(high-15/high-16/racknerd 등)에서는
    /// 초기화 도중에 주입된 부트스트랩이 셸 시작 시퀀스와 레이스를 일으켜 tmux가
    /// 제대로 뜨지 않거나 화면이 깨진 채로 남았다.
    ///
    /// 해법: 출력 펌프가 갱신하는 `lastOutputAt`를 보고, 배너·프롬프트가 다 그려진
    /// 뒤 출력이 `quietGap` 동안 잠잠해지면(= zle 준비 완료) 주입한다. 어떤 이유로든
    /// 안정 신호를 못 잡으면 `hardCap`에서 폴백 주입한다(느린 셸도 커버).
    private func injectBootstrapWhenReady() async {
        let quietGap: TimeInterval = 0.4      // 이만큼 출력이 없으면 프롬프트 안정으로 간주
        let hardCap = Date().addingTimeInterval(8.0)   // 안정 신호 실패 시 폴백 상한
        let poll: Duration = .milliseconds(50)
        // 1) 첫 출력(배너/프롬프트 시작)을 기다린다 — rc가 오래 침묵할 수 있다.
        while !sawShellOutput, Date() < hardCap {
            try? await Task.sleep(for: poll)
        }
        // 2) 출력이 quietGap 동안 잠잠해질 때까지(= 배너·프롬프트 렌더 종료) 기다린다.
        while Date() < hardCap {
            if sawShellOutput, Date().timeIntervalSince(lastOutputAt) >= quietGap { break }
            try? await Task.sleep(for: poll)
        }
        // exec tmux는 attach 시점의 PTY 크기로 창을 만든다. 프롬프트 안정까지 기다린
        // 이 시점엔 뷰 레이아웃이 끝나 실제 크기가 lastRequestedSize에 들어와 있으므로,
        // exec 직전에 PTY를 그 크기로 맞춰 tmux가 80×24가 아닌 실제 크기로 생성되게 한다.
        await applyPendingSize()
        try? await session.write(Data(Self.tmuxBootstrapLine().utf8))
    }

    /// 뷰가 마지막으로 요청한 크기를 원격 PTY에 재적용한다(없으면 무시).
    private func applyPendingSize() async {
        guard let sz = lastRequestedSize else { return }
        try? await session.resize(cols: sz.cols, rows: sz.rows)
    }

    /// tmux 세션 지속 부트스트랩. exec() 사이드채널은 Citadel 백엔드에만 구현되어
    /// 있어(libssh2는 "" 폴백) 프로브 대신 셸 stdin 주입으로 백엔드 무관하게 처리한다.
    ///
    /// `exec tmux …`: tmux가 있으면 로그인 셸을 tmux로 **대체**한다 — 접속하면 곧바로
    /// tmux가 세션 그 자체가 되고, 로그인 셸이 tmux "위/아래"에 따로 남지 않는다.
    /// (exec 없이 그냥 `tmux …`를 실행하면 로그인 셸이 부모로 남아, 사용자에겐 "루트
    /// 셸에서 tmux를 명령으로 띄운" 모양으로 보였다.) `command -v tmux` 가드로 tmux가
    /// 없으면 `&&`가 끊겨 exec에 도달하지 않으므로 일반 로그인 셸로 안전하게 폴백한다.
    /// 예전엔 exec가 "실패 시 채널이 닫힌다"는 이유로 회피됐지만, 이제 주입을 프롬프트
    /// 안정 이후로 게이팅(injectBootstrapWhenReady)해 명령이 온전히 전달되고, 가드가
    /// tmux 부재를 커버하므로 exec의 잔여 실패 위험(tmux는 있으나 new-session 실패)은
    /// 극히 드물다.
    nonisolated static func tmuxBootstrapLine() -> String {
        // `set-option -g window-size largest`: tmux 창을 "가장 큰 클라이언트" 크기에
        // 맞춘다. 없으면 세션이 처음 만들어진 크기(초기 80×24)에 갇혀, 실제 터미널이
        // 더 커도 좌상단 일부(예: 1/6)에만 그려진다. `largest`면 앱이 뷰 리사이즈 시
        // 보내는 크기를 따라 창이 100%로 커지고, 재접속 시 남은 작은 옛 클라이언트가
        // 있어도 (가장 큰) 우리 크기가 이긴다.
        //
        // `latest`가 아니라 `largest`인 이유: `latest`는 tmux 3.1+에서만 유효해서
        // 3.0a(예: Ubuntu 20.04) 서버에서는 "unknown value: latest" 에러로 부트스트랩이
        // 깨져 화면이 빈 채로 남았다. `largest`/`smallest`/`manual`은 tmux 2.9+ 전부에서
        // 유효하다.
        " command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s hydra \\; set-option -g window-size largest; clear\n"
    }

    func send(_ data: Data) { Task { try? await session.write(data) } }
    func resize(cols: Int, rows: Int) {
        lastRequestedSize = (cols, rows)   // 셸 오픈 전에 와서 버려져도 exec 직전 재적용된다
        Task { try? await session.resize(cols: cols, rows: rows) }
    }
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
        outputBuffer = Data()   // 새 셸 출력 스트림 — 이전 버퍼 잔재 제거
        lastOutputAt = .distantPast
        sawShellOutput = false
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.session.output {
                // injectBootstrapWhenReady가 프롬프트 안정 시점을 잡도록 매 청크 갱신.
                self.sawShellOutput = true
                self.lastOutputAt = Date()
                if let onOutput = self.onOutput {
                    onOutput(chunk)
                } else {
                    // 뷰가 아직 안 붙음 — 버퍼링 후 onOutput.didSet에서 재생.
                    self.outputBuffer.append(chunk)
                }
            }
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
