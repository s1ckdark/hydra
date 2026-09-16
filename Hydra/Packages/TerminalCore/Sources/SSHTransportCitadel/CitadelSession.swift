// vendored from iWorks/terminal @ 3b3545e — LOCALLY MODIFIED (see below), re-vendor requires re-applying these patches
import Foundation
import SSHTransport
import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Called during key exchange, before the server can receive credentials.
/// Throw to reject the presented host key. Approval must not be inferred from
/// a fingerprint captured after authentication has already completed.
public typealias SSHHostKeyVerifier = @Sendable (HostKeyFingerprint) async throws -> Void

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

    public var remoteHostKey: HostKeyFingerprint? {
        connectionLock.withLock { capturedHostKey }
    }

    private let connectionLock = NSLock()
    private let hostKeyVerifier: SSHHostKeyVerifier?
    private var capturedHostKey: HostKeyFingerprint?
    private var connectionAttempt: UUID?
    private var hostKeyValidation: HostKeyCapturingValidator?
    private var client: SSHClient?
    private var ptyTask: Task<Void, Never>?
    private var writeC: AsyncStream<Data>.Continuation?
    private var resizeC: AsyncStream<(Int, Int)>.Continuation?
    private var closeC: AsyncStream<Void>.Continuation?

    public init(hostKeyVerifier: SSHHostKeyVerifier? = nil) {
        self.hostKeyVerifier = hostKeyVerifier
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
        // Legacy key-auth sessions keep their app-layer TOFU behavior. Password
        // authentication, however, must never start without a pre-auth verifier.
        if case .password = auth, hostKeyVerifier == nil {
            throw SSHError.handshakeFailed("Password authentication requires a host-key verifier.")
        }
        try Task.checkCancellation()
        stC.yield(.connecting)
        let method: SSHAuthenticationMethod
        switch auth {
        case .password(let pwd):
            method = .passwordBased(username: user, password: pwd)
        case .privateKey(let pem, let passphrase):
            method = try Self.makeKeyAuth(user: user, pem: pem, passphrase: passphrase)
        }

        let attempt = UUID()
        let validator = HostKeyCapturingValidator(onCapture: { [weak self] fingerprint in
            guard let self else { return }
            self.connectionLock.withLock {
                guard self.connectionAttempt == attempt else { return }
                self.capturedHostKey = fingerprint
            }
        }, verifier: hostKeyVerifier)
        let previous = connectionLock.withLock { () -> (HostKeyCapturingValidator?, SSHClient?) in
            let previous = (hostKeyValidation, client)
            connectionAttempt = attempt
            capturedHostKey = nil
            hostKeyValidation = validator
            client = nil
            return previous
        }
        previous.0?.cancelPendingValidation()
        if let previousClient = previous.1 {
            Task { try? await previousClient.close() }
        }

        do {
            let connectedClient = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await SSHClient.connect(
                    host: host,
                    port: port,
                    authenticationMethod: method,
                    hostKeyValidator: .custom(validator),
                    reconnect: .never
                )
            } onCancel: {
                validator.cancelPendingValidation()
            }
            // Citadel's connect future does not propagate Swift task cancellation.
            // A late completion after disconnect/replacement must be closed, never
            // installed as the current client's authenticated connection.
            // Do not acquire the validation lock while holding connectionLock:
            // a same-loop host-validation completion may synchronously reenter
            // disconnect through an SSH callback.
            let validationCancelled = validator.isCancelled
            let accepted = connectionLock.withLock { () -> Bool in
                guard connectionAttempt == attempt, !Task.isCancelled, !validationCancelled else {
                    return false
                }
                client = connectedClient
                return true
            }
            guard accepted else {
                try? await connectedClient.close()
                throw CancellationError()
            }
            stC.yield(.connected)
        } catch {
            let verificationError = validator.failure
            let wasCancelled = Task.isCancelled || validator.isCancelled || error is CancellationError
            validator.cancelPendingValidation()
            // Host-key rejection and cancellation are authoritative. Only
            // generic transport failures are classified; never display raw
            // Citadel/NIO diagnostics or collapse network errors into auth.
            let reportedError: Error = verificationError
                ?? (wasCancelled ? CancellationError() : Self.classify(error: error))
            if connectionLock.withLock({ connectionAttempt == attempt }) {
                stC.yield(.disconnected(reason: reportedError is CancellationError ? nil : reportedError.localizedDescription))
            }
            throw reportedError
        }
    }

    public func openShell(termType: String, cols: Int, rows: Int) async throws {
        guard let client = connectionLock.withLock({ client }) else {
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
        guard let client = connectionLock.withLock({ client }) else {
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

    public func execDirect(_ command: String) async throws -> String {
        guard let client = connectionLock.withLock({ client }) else {
            throw SSHError.channelFailed("not connected")
        }
        try Task.checkCancellation()
        do {
            let buf = try await client.executeCommand(
                command, maxResponseSize: 16 * 1024, mergeStreams: false, inShell: false
            )
            try Task.checkCancellation()
            return String(decoding: buf.readableBytesView, as: UTF8.self)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Self.classify(error: error)
        }
    }

    public func disconnect() {
        let previous = connectionLock.withLock { () -> (HostKeyCapturingValidator?, SSHClient?) in
            connectionAttempt = nil
            let previous = (hostKeyValidation, client)
            hostKeyValidation = nil
            client = nil
            return previous
        }
        previous.0?.cancelPendingValidation()
        closeC?.finish()
        writeC?.finish()
        resizeC?.finish()
        Task { try? await previous.1?.close() }
        outC.finish()
        stC.finish()
    }

    // MARK: Helpers

    /// Classifies only concrete error types/codes, never localized strings.
    /// The depth bound also prevents malformed NSError underlying-error chains
    /// from trapping or recursing indefinitely.
    static func classify(error: Error, depth: Int = 0) -> SSHFailure {
        guard depth < 8 else { return .unknown }
        if let failure = error as? SSHFailure { return failure }
        if let command = error as? SSHClient.CommandFailed { return .commandFailed(exitStatus: command.exitCode) }
        if error is AuthenticationFailed { return .authenticationRejected }
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed: return .authenticationRejected
            case .unsupportedPasswordAuthentication: return .passwordAuthenticationUnsupported
            case .unsupportedPrivateKeyAuthentication: return .privateKeyAuthenticationUnsupported
            case .channelCreationFailed: return .channelUnavailable
            case .unsupportedHostBasedAuthentication: return .unknown
            }
        }
        if let connection = error as? NIOConnectionError {
            // A failed DNS family must not obscure a real connection failure
            // against an address resolved by the other family.
            for attempt in connection.connectionErrors {
                let cause = classify(error: attempt.error, depth: depth + 1)
                if cause != .unknown { return cause }
            }
            if connection.connectionErrors.isEmpty,
               connection.dnsAError != nil || connection.dnsAAAAError != nil {
                return .nameResolutionFailed
            }
            return .unknown
        }
        if error is SocketAddressError.UnknownHost { return .nameResolutionFailed }
        if let address = error as? SocketAddressError {
            switch address {
            case .unknown, .failedToParseIPString: return .nameResolutionFailed
            default: return .unknown
            }
        }
        if let io = error as? IOError { return classifyPOSIX(code: Int(io.errnoCode)) }
        if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout: return .timedOut
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof: return .connectionLost
            case .writeHostUnreachable: return .networkUnavailable
            default: return .unknown
            }
        }
        if let ssh = error as? NIOSSHError {
            switch ssh.type {
            case .tcpShutdown, .creatingChannelAfterClosure: return .connectionLost
            case .invalidUserAuthSignature: return .authenticationRejected
            case .channelSetupRejected: return .channelUnavailable
            case .keyExchangeNegotiationFailure, .unsupportedVersion,
                 .invalidHostKeyForKeyExchange, .unknownPublicKey, .unknownSignature,
                 .invalidExchangeHashSignature, .weakSharedSecret,
                 .invalidDomainParametersForKey:
                return .handshakeFailed
            // Packet/protocol errors can arise after authentication, too.
            // Their types alone do not establish a failed handshake.
            default: return .unknown
            }
        }
        if let citadel = error as? CitadelError {
            switch citadel {
            case .commandOutputTooLarge: return .commandOutputTooLarge
            case .unauthorized: return .authenticationRejected
            case .channelCreationFailed, .channelFailure: return .channelUnavailable
            default: return .handshakeFailed
            }
        }
        if let legacy = error as? SSHError {
            switch legacy {
            // Older transports also use authFailed for network failures and
            // unreadable local keys, so it is not proof of server rejection.
            case .authFailed: return .unknown
            case .handshakeFailed: return .handshakeFailed
            case .unreachable: return .networkUnavailable
            case .disconnected: return .connectionLost
            case .channelFailed: return .unknown
            }
        }
        let nsError = error as NSError
        var knownCause: SSHFailure = .unknown
        if nsError.domain == NSPOSIXErrorDomain {
            knownCause = classifyPOSIX(code: nsError.code)
        } else if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: knownCause = .nameResolutionFailed
            case NSURLErrorTimedOut: knownCause = .timedOut
            case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet: knownCause = .networkUnavailable
            case NSURLErrorNetworkConnectionLost: knownCause = .connectionLost
            case NSURLErrorUserAuthenticationRequired: knownCause = .authenticationRejected
            case NSURLErrorSecureConnectionFailed: knownCause = .handshakeFailed
            default: break
            }
        }
        if knownCause != .unknown { return knownCause }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return classify(error: underlying, depth: depth + 1)
        }
        return .unknown
    }

    private static func classifyPOSIX(code: Int) -> SSHFailure {
        switch code {
        case Int(ECONNREFUSED): return .connectionRefused
        case Int(ETIMEDOUT): return .timedOut
        case Int(ENETUNREACH), Int(EHOSTUNREACH), Int(ENETDOWN), Int(EHOSTDOWN): return .networkUnavailable
        case Int(ECONNRESET), Int(ECONNABORTED), Int(EPIPE), Int(ENOTCONN): return .connectionLost
        default: return .unknown
        }
    }

    /// Derive the public component from parsed private material, not the
    /// unauthenticated public-key header of an OpenSSH private-key container.
    /// Returns only `algorithm base64`, with no comment or private material.
    public static func publicKeyLine(fromPrivateKey pem: Data,
                                     passphrase: String? = nil) throws -> String {
        let passData = passphrase?.data(using: .utf8)
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passData) {
            return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: passData) {
            return String(openSSHPublicKey: NIOSSHPrivateKey(custom: key).publicKey)
        }
        throw SSHError.authFailed("Unsupported or unreadable private key (Ed25519/RSA only).")
    }

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

// Internal for focused handshake-promise tests. The delegate has no strong
// reference to CitadelSession. Pending promises are resolved exactly once,
// including when a user cancels while an async trust prompt is still awaiting.
final class HostKeyCapturingValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private struct Pending {
        let promise: EventLoopPromise<Void>
        var task: Task<Void, Never>?
    }

    private let onCapture: @Sendable (HostKeyFingerprint) -> Void
    private let verifier: SSHHostKeyVerifier?
    // Completion runs on the promise event loop while this lock is held. NIO
    // may synchronously invoke a callback that cancels this validator, so the
    // lock must allow same-thread reentry while excluding concurrent cancel.
    private let lock = NSRecursiveLock()
    private var pending: [UUID: Pending] = [:]
    private var cancelled = false
    private var validationFailure: Error?

    var isCancelled: Bool { lock.withLock { cancelled } }
    var failure: Error? { lock.withLock { validationFailure } }

    init(onCapture: @escaping @Sendable (HostKeyFingerprint) -> Void,
         verifier: SSHHostKeyVerifier?) {
        self.onCapture = onCapture
        self.verifier = verifier
    }

    func validateHostKey(hostKey: NIOSSHPublicKey,
                         validationCompletePromise promise: EventLoopPromise<Void>) {
        let rendered = String(openSSHPublicKey: hostKey)
        let parts = rendered.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let keyBytes = Data(base64Encoded: String(parts[1])) else {
            promise.fail(SSHError.handshakeFailed("Could not read the server host key."))
            return
        }
        let fingerprint = HostKeyFingerprint(
            keyType: String(parts[0]), publicKeyBase64: String(parts[1]),
            sha256Hex: SHA256.hash(data: keyBytes).map { String(format: "%02x", $0) }.joined()
        )
        let id = UUID()
        let registered = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            pending[id] = Pending(promise: promise, task: nil)
            return true
        }
        guard registered else {
            promise.fail(CancellationError())
            return
        }
        onCapture(fingerprint)
        guard let verifier else {
            complete(id: id, result: .success(()))
            return
        }
        lock.withLock {
            guard pending[id] != nil, !cancelled else { return }
            // Register the task before cancellation can remove the pending
            // promise. The task's initial lock read also waits for this setup
            // to finish before the verifier can display a trust prompt.
            pending[id]?.task = Task {
                do {
                    try Task.checkCancellation()
                    guard !self.isCancelled else { throw CancellationError() }
                    try await verifier(fingerprint)
                    try Task.checkCancellation()
                    self.complete(id: id, result: .success(()))
                } catch {
                    self.complete(id: id, result: .failure(error))
                }
            }
        }
    }

    func cancelPendingValidation() {
        let abandoned = lock.withLock { () -> [Pending] in
            cancelled = true
            if validationFailure == nil { validationFailure = CancellationError() }
            let abandoned = Array(pending.values)
            pending.removeAll()
            return abandoned
        }
        for validation in abandoned {
            validation.task?.cancel()
            validation.promise.fail(CancellationError())
        }
    }

    private func complete(id: UUID, result: Result<Void, Error>) {
        guard let eventLoop = lock.withLock({ pending[id]?.promise.futureResult.eventLoop }) else {
            return
        }
        eventLoop.execute {
            self.lock.withLock {
                guard let validation = self.pending.removeValue(forKey: id) else { return }
                if case .failure(let error) = result { self.validationFailure = error }
                // Removing pending and actually resolving on its event loop
                // are one critical section: cancel cannot return in between
                // and then allow a still-pending promise to succeed afterward.
                validation.promise.completeWith(result)
            }
        }
    }
}
