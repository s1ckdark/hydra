// vendored from iWorks/terminal @ 3b3545e, do not edit here
import Foundation
import SSHTransport
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// Pure-Swift SSH session backed by Citadel (NIO + NIOSSH). Works on iOS,
/// macCatalyst, and macOS. Replaces the Shout-based LibSSH2Session for
/// platforms where libssh2 isn't available (Catalyst).
///
/// `@unchecked Sendable`: the type is mutable but every internal mutation
/// either runs on the connect/openShell async chain or via AsyncStream
/// continuations (which are themselves Sendable). External callers only
/// touch the streams, which are safe to share across tasks.
public final class CitadelSession: SSHSession, @unchecked Sendable {

    public let output: AsyncStream<Data>
    public let state:  AsyncStream<SSHState>
    private let outC: AsyncStream<Data>.Continuation
    private let stC:  AsyncStream<SSHState>.Continuation

    public private(set) var remoteHostKey: HostKeyFingerprint? = nil
    // TODO: surface a real fingerprint via a custom hostKeyValidator. For
    // MVP we accept-anything, so TOFU is best-effort (skipped) — same as the
    // Shout path's behaviour.

    private var client: SSHClient?
    private var ptyTask: Task<Void, Never>?
    private var writeC: AsyncStream<Data>.Continuation?
    private var resizeC: AsyncStream<(Int, Int)>.Continuation?
    private var closeC: AsyncStream<Void>.Continuation?

    public init() {
        var oc: AsyncStream<Data>.Continuation!
        output = AsyncStream { oc = $0 }
        outC = oc
        var sc: AsyncStream<SSHState>.Continuation!
        state = AsyncStream { sc = $0 }
        stC = sc
    }

    // MARK: SSHSession

    public func connect(host: String, port: Int, user: String,
                        auth: SSHAuth) async throws {
        stC.yield(.connecting)
        let method: SSHAuthenticationMethod
        switch auth {
        case .password(let pwd):
            method = .passwordBased(username: user, password: pwd)
        case .privateKey(let pem, let passphrase):
            method = try Self.makeKeyAuth(user: user, pem: pem, passphrase: passphrase)
        }

        do {
            client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: method,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            stC.yield(.connected)
        } catch {
            stC.yield(.disconnected(reason: error.localizedDescription))
            throw SSHError.authFailed(error.localizedDescription)
        }
    }

    public func openShell(termType: String, cols: Int, rows: Int) async throws {
        guard let client = client else {
            throw SSHError.channelFailed("not connected")
        }

        var wc: AsyncStream<Data>.Continuation!
        let writes = AsyncStream<Data> { wc = $0 }
        writeC = wc

        var rc: AsyncStream<(Int, Int)>.Continuation!
        let resizes = AsyncStream<(Int, Int)> { rc = $0 }
        resizeC = rc

        var cc: AsyncStream<Void>.Continuation!
        let closes = AsyncStream<Void> { cc = $0 }
        closeC = cc

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: termType,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        ptyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    // Pump inbound chunks → output stream. When the remote
                    // shell closes (e.g. user types `exit`) the inbound
                    // sequence ends — propagate that to our closes stream so
                    // the surrounding `for await _ in closes` releases the
                    // PTY closure and the disconnected state is yielded.
                    let readTask = Task {
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buf), .stderr(let buf):
                                self.outC.yield(Data(buf.readableBytesView))
                            }
                        }
                        self.closeC?.finish()
                    }
                    // Pump app writes → outbound.
                    let writeTask = Task {
                        for await data in writes {
                            try await outbound.write(ByteBuffer(bytes: data))
                        }
                    }
                    // Pump resize requests → outbound.changeSize.
                    let resizeTask = Task {
                        for await (c, r) in resizes {
                            try await outbound.changeSize(
                                cols: c, rows: r,
                                pixelWidth: 0, pixelHeight: 0
                            )
                        }
                    }
                    // Hold the closure open until disconnect() finishes the close stream.
                    for await _ in closes { /* never iterates — finish() is the signal */ }
                    readTask.cancel()
                    writeTask.cancel()
                    resizeTask.cancel()
                }
                self.stC.yield(.disconnected(reason: nil))
            } catch {
                self.stC.yield(.disconnected(reason: error.localizedDescription))
            }
        }
    }

    public func write(_ data: Data) async throws {
        writeC?.yield(data)
    }

    public func resize(cols: Int, rows: Int) async throws {
        resizeC?.yield((cols, rows))
    }

    public func exec(_ command: String) async throws -> String {
        guard let client = client else {
            throw SSHError.channelFailed("not connected")
        }
        // Side-channel exec: bytes do NOT flow through `output` (no PTY).
        // `inShell: true` runs through the user's login shell so $SHELL,
        // /etc/profile, etc. are honoured; `mergeStreams: true` captures
        // stderr too because some probes (e.g. `sw_vers` on a missing macOS)
        // write to stderr.
        let buf = try await client.executeCommand(
            command, mergeStreams: true, inShell: true
        )
        return String(decoding: buf.readableBytesView, as: UTF8.self)
    }

    public func disconnect() {
        closeC?.finish()
        writeC?.finish()
        resizeC?.finish()
        Task { [client] in try? await client?.close() }
        client = nil
        outC.finish()
        stC.finish()
    }

    // MARK: Helpers

    private static func makeKeyAuth(user: String, pem: Data,
                                    passphrase: String?) throws -> SSHAuthenticationMethod {
        let pemString = String(decoding: pem, as: UTF8.self)
        let passData = passphrase?.data(using: .utf8)

        // Try Ed25519 first (modern default for OpenSSH keys), fall back to RSA.
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pemString,
                                                         decryptionKey: passData) {
            return .ed25519(username: user, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: pemString) {
            return .rsa(username: user, privateKey: key)
        }
        throw SSHError.authFailed("Unsupported private key format (Ed25519/RSA only).")
    }
}
