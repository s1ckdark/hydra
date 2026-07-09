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
    private var readTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "ssh.io")

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
            queue.async {
                do {
                    let ch = try ssh.openShellChannel()
                    try ch.requestPty(type: termType, cols: Int32(cols), rows: Int32(rows))
                    try ch.requestShell()
                    self.shell = ch
                    self.startReadLoop(channel: ch)
                    cont.resume()
                } catch {
                    cont.resume(throwing: SSHError.channelFailed(error.localizedDescription))
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard let shell = shell else { throw SSHError.channelFailed("shell not open") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                var remaining = data
                while !remaining.isEmpty {
                    switch shell.write(data: remaining, length: remaining.count) {
                    case .written(let n):
                        if n >= remaining.count {
                            remaining = Data()
                        } else {
                            remaining = remaining.advanced(by: n)
                        }
                    case .eagain:
                        // spin — session is blocking, so eagain is transient
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

    private func startReadLoop(channel: Channel) {
        readTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let result = channel.readData()
                switch result {
                case .data(let chunk):
                    self.outC.yield(chunk)
                case .eagain:
                    try? await Task.sleep(nanoseconds: 20_000_000)
                case .done:
                    // EOF — channel closed cleanly
                    self.stC.yield(.disconnected(reason: nil))
                    return
                case .error(let err):
                    self.stC.yield(.disconnected(reason: err.localizedDescription))
                    return
                }
            }
        }
    }

    public func resize(cols: Int, rows: Int) async throws {
        guard let shell = shell else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try shell.requestPtySize(width: Int32(cols), height: Int32(rows))
                    cont.resume()
                } catch {
                    cont.resume(throwing: SSHError.channelFailed(error.localizedDescription))
                }
            }
        }
    }

    public func disconnect() {
        readTask?.cancel()
        queue.async {
            try? self.shell?.close()
            self.shell = nil
            self.ssh = nil
        }
        stC.yield(.disconnected(reason: nil))
        outC.finish()
        stC.finish()
    }
}
#endif
