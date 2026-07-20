// vendored from iWorks/terminal @ 3b3545e — LOCALLY MODIFIED: implemented
// remoteHostKey capture (see connect() and hostKeyFingerprint(from:) below),
// which the upstream file left as a TODO. Uses SSH.hostKeyRaw(), a Hydra
// addition to the vendored Shout copy (Sources/Shout/Session.swift +
// Sources/Shout/SSH.swift) that wraps libssh2_session_hostkey +
// libssh2_hostkey_hash — upstream Shout exposes neither the raw
// libssh2_session pointer nor a host-key accessor.
import Foundation
import SSHTransport
#if canImport(Shout)
import Shout

public final class LibSSH2Session: SSHSession {

    public let output: AsyncStream<Data>
    public let state:  AsyncStream<SSHState>
    private let outC: AsyncStream<Data>.Continuation
    private let stC:  AsyncStream<SSHState>.Continuation

    public private(set) var remoteHostKey: HostKeyFingerprint? = nil

    private var ssh: SSH?
    private var shell: Channel?
    /// 모든 libssh2 접근을 직렬화하는 단 하나의 큐. connect/auth, 셸 오픈, read
    /// 폴링, write, resize, teardown이 전부 이 큐에서만 실행된다. libssh2 세션은
    /// 스레드-세이프가 아니므로, 두 스레드가 동시에 세션을 만지면(예전엔 read가
    /// detached 스레드에서 돌았다) 크래시한다 — 큐 단일화로 원천 차단한다.
    private let queue = DispatchQueue(label: "ssh.io")
    /// teardown 이후 늦게 도는 read 틱/큐 작업이 해제된 채널·세션을 건드리지 않게
    /// 하는 가드. teardownLocked에서만 true로 바뀌고, 이 인스턴스는 재사용되지
    /// 않는다(재연결은 sessionFactory가 새 인스턴스를 만든다).
    private var closed = false

    public init() {
        var oc: AsyncStream<Data>.Continuation!
        output = AsyncStream { oc = $0 }
        outC = oc
        var sc: AsyncStream<SSHState>.Continuation!
        state = AsyncStream { sc = $0 }
        stC = sc
    }

    public func connect(host: String, port: Int, user: String,
                        auth: SSHAuth) async throws {
        stC.yield(.connecting)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let ssh = try SSH(host: host, port: Int32(port))
                    switch auth {
                    case .privateKey(let pem, let passphrase):
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ipad-tmp-\(UUID().uuidString).pem")
                        try pem.write(to: tmp)
                        defer { try? FileManager.default.removeItem(at: tmp) }
                        try ssh.authenticate(username: user,
                                             privateKey: tmp.path,
                                             passphrase: passphrase)
                    case .password(let pwd):
                        try ssh.authenticate(username: user, password: pwd)
                    }
                    self.ssh = ssh
                    self.remoteHostKey = Self.hostKeyFingerprint(from: ssh)
                    self.stC.yield(.connected)
                    cont.resume()
                } catch {
                    self.stC.yield(.disconnected(reason: error.localizedDescription))
                    cont.resume(throwing: SSHError.authFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Host-key capture

    /// Renders libssh2's raw host-key material (key-type constant, wire-format
    /// public key bytes, SHA256 digest) into the HostKeyFingerprint the
    /// app-layer TOFU gate (HostKeyGate/KnownHostsStore) compares against.
    /// Returns nil (rather than throwing) if libssh2 can't supply the key —
    /// callers already treat a nil remoteHostKey as "TOFU can't run yet".
    private static func hostKeyFingerprint(from ssh: SSH) -> HostKeyFingerprint? {
        guard let raw = ssh.hostKeyRaw() else { return nil }
        let sha256Hex = raw.sha256.map { String(format: "%02x", $0) }.joined()
        return HostKeyFingerprint(keyType: opensshKeyTypeName(for: raw.type),
                                  publicKeyBase64: raw.keyBytes.base64EncodedString(),
                                  sha256Hex: sha256Hex)
    }

    /// Maps libssh2's LIBSSH2_HOSTKEY_TYPE_* constants to the OpenSSH
    /// algorithm names used elsewhere in the app (KnownHosts entries, the
    /// "algorithm base64key" openssh-known-hosts wire format).
    private static func opensshKeyTypeName(for libssh2Type: Int32) -> String {
        switch libssh2Type {
        case 1: return "ssh-rsa"                  // LIBSSH2_HOSTKEY_TYPE_RSA
        case 2: return "ssh-dss"                  // LIBSSH2_HOSTKEY_TYPE_DSS (deprecated)
        case 3: return "ecdsa-sha2-nistp256"       // LIBSSH2_HOSTKEY_TYPE_ECDSA_256
        case 4: return "ecdsa-sha2-nistp384"       // LIBSSH2_HOSTKEY_TYPE_ECDSA_384
        case 5: return "ecdsa-sha2-nistp521"       // LIBSSH2_HOSTKEY_TYPE_ECDSA_521
        case 6: return "ssh-ed25519"               // LIBSSH2_HOSTKEY_TYPE_ED25519
        default: return "unknown"
        }
    }

    // MARK: - Shell (Task 15)
    // API adaptations vs. plan:
    //   • ssh.openShellChannel() replaces ssh.openChannel() — Shout has no public openChannel()
    //   • requestPty(type:cols:rows:) added to Channel (plan used non-existent width:/height: labels)
    //   • requestShell() added to Channel via libssh2_channel_process_startup("shell",...)
    //   • channel.readData() returns ReadWriteProcessor.ReadResult enum, not raw Data
    //   • channel.write(data:length:) returns ReadWriteProcessor.WriteResult enum, not Void/throws

    public func openShell(termType: String, cols: Int, rows: Int) async throws {
        guard let ssh = ssh else { throw SSHError.channelFailed("no session") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, !self.closed else {
                    cont.resume(throwing: SSHError.channelFailed("session closed"))
                    return
                }
                do {
                    let ch = try ssh.openShellChannel()
                    try ch.requestPty(type: termType, cols: Int32(cols), rows: Int32(rows))
                    try ch.requestShell()
                    // 셸 준비까지는 블로킹으로(간단·일회성). 이후 대화형 I/O는 논블로킹으로
                    // 전환해, 이 직렬 큐가 read 폴링과 write/resize를 모두 인터리브한다.
                    ssh.setBlocking(false)
                    self.shell = ch
                    self.scheduleReadTick()
                    cont.resume()
                } catch {
                    cont.resume(throwing: SSHError.channelFailed(error.localizedDescription))
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, let shell = self.shell, !self.closed else {
                    cont.resume(throwing: SSHError.channelFailed("shell not open"))
                    return
                }
                var remaining = data
                while !remaining.isEmpty {
                    switch shell.write(data: remaining, length: remaining.count) {
                    case .written(let n):
                        remaining = n >= remaining.count ? Data() : remaining.advanced(by: n)
                    case .eagain:
                        // 논블로킹: 송신 버퍼가 잠깐 찼을 뿐 — 큐를 완전히 점유하지
                        // 않도록 아주 짧게 쉬고 재시도한다(대화형 키 입력은 소량이라
                        // 사실상 즉시 완료된다).
                        usleep(500)
                        continue
                    case .error(let err):
                        cont.resume(throwing: SSHError.channelFailed(err.localizedDescription))
                        return
                    }
                }
                cont.resume()
            }
        }
    }

    /// 직렬 큐에서 도는 논블로킹 read 폴링. 매 틱마다 가용 데이터를 전부 비운 뒤
    /// 다음 틱을 예약한다(활성 1ms / 유휴 20ms). detached read 스레드를 없애 read가
    /// write/resize와 같은 큐에서 직렬화되므로, libssh2 세션을 단일 스레드만 만진다.
    private func scheduleReadTick() {
        queue.async { [weak self] in
            guard let self, !self.closed, let shell = self.shell else { return }
            var sawData = false
            loop: while !self.closed {
                switch shell.readData() {
                case .data(let chunk):
                    self.outC.yield(chunk)
                    sawData = true
                case .eagain:
                    break loop
                case .done:
                    self.stC.yield(.disconnected(reason: nil))
                    self.teardownLocked()
                    return
                case .error(let err):
                    self.stC.yield(.disconnected(reason: err.localizedDescription))
                    self.teardownLocked()
                    return
                }
            }
            guard !self.closed else { return }
            let delay: DispatchTimeInterval = sawData ? .milliseconds(1) : .milliseconds(20)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scheduleReadTick()
            }
        }
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, let shell = self.shell, !self.closed else {
                    cont.resume()   // 셸이 없거나 닫힘 — 리사이즈는 무시(에러 아님)
                    return
                }
                // 논블로킹 모드에선 EAGAIN이 날 수 있으므로 best-effort 재시도.
                shell.requestPtySizeNonblocking(width: Int32(cols), height: Int32(rows))
                cont.resume()
            }
        }
    }

    /// 반드시 `queue`에서만 호출. 채널을 세션보다 **먼저**, 그리고 이 큐 스레드에서
    /// free한다 — 예전엔 detached read 스레드가 마지막으로 채널을 놓아, 세션이 이미
    /// free된 뒤(use-after-free)·다른 스레드에서 libssh2_channel_free가 돌아
    /// 크래시했다. 순서(채널→세션)와 스레드(큐)를 모두 고정해 원천 차단한다.
    private func teardownLocked() {
        guard !closed else { return }
        closed = true
        try? shell?.close()
        shell = nil   // Channel.deinit → libssh2_channel_free (세션은 아직 살아있음)
        ssh = nil     // SSH→Session.deinit → libssh2_session_free (채널 free 이후)
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.teardownLocked()
        }
        stC.yield(.disconnected(reason: nil))
        outC.finish()
        stC.finish()
    }
}
#endif
