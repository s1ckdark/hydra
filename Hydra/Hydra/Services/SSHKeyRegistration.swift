import Foundation
import CryptoKit
import KnownHosts
import SSHTransport
import SSHTransportCitadel

struct SSHKeyRegistrationTarget: Equatable, Sendable {
    let host: String
    let user: String
    let port: Int

    init(host: String, user: String, port: Int = 22) {
        self.host = host
        self.user = user
        self.port = port
    }

    var knownHostIdentity: String { port == 22 ? host : "[\(host)]:\(port)" }

    func validate() throws {
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:%")
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy(allowedHost.contains),
              (1...65535).contains(port), Self.isValidUser(user) else {
            throw SSHKeyRegistrationError.invalidTarget
        }
    }

    static func isValidUser(_ user: String) -> Bool {
        let initial = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let rest = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-$")
        return !user.isEmpty && user.utf8.count <= 128
            && user.unicodeScalars.first.map(initial.contains) == true
            && user.unicodeScalars.allSatisfy(rest.contains)
    }
}

enum SSHKeyRegistrationProgress: Equatable, Sendable {
    case checkingHost, awaitingHostApproval, connecting, registering, verifying
}

struct SSHKeyRegistrationResult: Equatable, Sendable {
    let alreadyRegistered: Bool
}

enum SSHKeyRegistrationError: Error, Equatable, Sendable {
    case invalidTarget, invalidPublicKey, invalidPassword
    case hostRejected, hostMismatch, registrationFailed
    case verificationFailed(mayHaveRegistered: Bool)
    case cancelled(mayHaveRegistered: Bool)
    case connectionFailed(SSHFailure)
    case trustStoreUnavailable
    case remoteCommandFailed(exitStatus: Int)
    case registrationInterrupted(SSHFailure)
    case keyLoginFailed(SSHFailure)
    case keyLoginHostMismatch
}

struct SSHKeyRegistrationPublicKey: Equatable, Sendable {
    let publicKeyLine: String
    let fingerprint: String
}

@MainActor
protocol SSHKeyRegistering: AnyObject {
    func register(
        target: SSHKeyRegistrationTarget,
        privateKey: Data,
        password: String,
        approveHost: @escaping @MainActor (HostKeyFingerprint) async -> Bool,
        onProgress: @escaping @MainActor (SSHKeyRegistrationProgress) -> Void
    ) async throws -> SSHKeyRegistrationResult
    func cancel()
}

enum SSHKeyRegistrationCommand {
    static func publicKeySummary(fromPrivateKey privateKey: Data) throws -> SSHKeyRegistrationPublicKey {
        let line: String
        do { line = try CitadelSession.publicKeyLine(fromPrivateKey: privateKey) }
        catch { throw SSHKeyRegistrationError.invalidPublicKey }
        let parts = try validatedKey(line)
        let digest = Data(SHA256.hash(data: parts.blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return .init(publicKeyLine: line, fingerprint: "SHA256:" + digest)
    }

    /// A POSIX shell command intended to run while logged in as the chosen account.
    /// It adds only the public key; private material is never part of this command.
    static func make(publicKeyLine: String, expectedUser: String, marker: String) throws -> String {
        let key = try validatedKey(publicKeyLine)
        guard SSHKeyRegistrationTarget.isValidUser(expectedUser),
              marker.hasPrefix("HYDRA_KEY_"), marker.count <= 128,
              marker.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_").contains) else {
            throw SSHKeyRegistrationError.invalidTarget
        }
        let script = #"""
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        [ "$(id -un)" = \#(quote(expectedUser)) ] || exit 20
        case "${HOME:-}" in /*) ;; *) exit 21 ;; esac
        umask 077
        hydra_dir="$HOME/.ssh"
        [ ! -L "$hydra_dir" ] || exit 22
        if [ -e "$hydra_dir" ]; then
            [ -d "$hydra_dir" ] || exit 22
        else
            mkdir -m 700 "$hydra_dir" || exit 30
        fi
        hydra_lock="$hydra_dir/.hydra-key-registration.lock"
        hydra_attempt=0
        until mkdir -m 700 "$hydra_lock" 2>/dev/null; do
            hydra_attempt=$((hydra_attempt + 1))
            [ "$hydra_attempt" -lt 10 ] || exit 23
            sleep 1
        done
        trap 'rmdir "$hydra_lock" 2>/dev/null || :' EXIT
        trap 'exit 24' HUP INT TERM
        [ ! -L "$hydra_dir" ] && [ -d "$hydra_dir" ] || exit 22
        hydra_file="$hydra_dir/authorized_keys"
        [ ! -L "$hydra_file" ] || exit 25
        if [ -e "$hydra_file" ]; then
            [ -f "$hydra_file" ] || exit 25
        else
            (set -C; : > "$hydra_file") || exit 31
        fi
        [ ! -L "$hydra_file" ] && [ -f "$hydra_file" ] || exit 25
        chmod 700 "$hydra_dir" || exit 26
        chmod 600 "$hydra_file" || exit 26
        [ -r "$hydra_file" ] && [ -w "$hydra_file" ] || exit 26
        if awk -v key_type=\#(quote(key.type)) -v key_blob=\#(quote(key.base64)) '
            function token(    c, value, quoted, escaped) {
                value = ""; quoted = 0; escaped = 0
                while (cursor <= length($0) && substr($0, cursor, 1) ~ /[ \t\r]/) cursor++
                while (cursor <= length($0)) {
                    c = substr($0, cursor++, 1)
                    if (!quoted && c ~ /[ \t\r]/) break
                    value = value c
                    if (escaped) { escaped = 0; continue }
                    if (c == "\\" && quoted) { escaped = 1; continue }
                    if (c == "\"") quoted = !quoted
                }
                return value
            }
            {
                cursor = 1; first = token()
                if (first == "" || substr(first, 1, 1) == "#") next
                if (first == key_type) {
                    if (token() == key_blob) found = 1
                } else if (token() == key_type && token() == key_blob) found = 1
            }
            END { exit found ? 0 : 1 }
        ' "$hydra_file"; then
            printf '%s\n' \#(quote(marker + ":exists"))
        else
            hydra_awk_status=$?
            [ "$hydra_awk_status" -eq 1 ] || exit 27
            if [ -s "$hydra_file" ]; then
                hydra_last=$(tail -c 1 "$hydra_file" | od -An -tu1 | tr -d '[:space:]')
                [ -n "$hydra_last" ] || exit 27
                if [ "$hydra_last" != 10 ]; then printf '\n' >> "$hydra_file" || exit 28; fi
            fi
            printf '%s\n' \#(quote(publicKeyLine)) >> "$hydra_file" || exit 28
            printf '%s\n' \#(quote(marker + ":added"))
        fi
        """#
        // Run the POSIX script in sh, including when the login shell is fish.
        return "sh -c " + quote(script)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func validatedKey(_ line: String) throws -> (type: String, base64: String, blob: Data) {
        guard !line.isEmpty, line.utf8.count <= 32_768,
              !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SSHKeyRegistrationError.invalidPublicKey
        }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, ["ssh-ed25519", "ssh-rsa"].contains(String(parts[0])),
              let blob = Data(base64Encoded: String(parts[1])), blob.count <= 16_384 else {
            throw SSHKeyRegistrationError.invalidPublicKey
        }
        let bytes = [UInt8](blob)
        var offset = 0
        func field() -> [UInt8]? {
            guard offset + 4 <= bytes.count else { return nil }
            let count = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard Int(count) <= bytes.count - offset else { return nil }
            let result = Array(bytes[offset..<(offset + Int(count))])
            offset += Int(count)
            return result
        }
        guard let wireType = field(), String(bytes: wireType, encoding: .utf8) == String(parts[0]) else {
            throw SSHKeyRegistrationError.invalidPublicKey
        }
        if parts[0] == "ssh-ed25519" {
            guard field()?.count == 32 else { throw SSHKeyRegistrationError.invalidPublicKey }
        } else {
            guard let exponent = field(), !exponent.isEmpty, exponent.contains(where: { $0 != 0 }),
                  let modulus = field(), !modulus.isEmpty, modulus.contains(where: { $0 != 0 }) else {
                throw SSHKeyRegistrationError.invalidPublicKey
            }
        }
        guard offset == bytes.count else { throw SSHKeyRegistrationError.invalidPublicKey }
        return (String(parts[0]), String(parts[1]), blob)
    }
}

@MainActor
final class SSHKeyRegistrationService: SSHKeyRegistering {
    private final class Operation {
        var session: SSHSession?
        var fingerprint: HostKeyFingerprint?
        var mayHaveRegistered = false
        var phase: SSHKeyRegistrationProgress = .checkingHost
    }
    private struct HostProbeCaptured: Error {}

    private let knownHosts: KnownHostsStore
    private let sessionFactory: (@escaping SSHHostKeyVerifier) -> SSHSession
    private var operation: Operation?

    init(knownHostsURL: URL? = nil,
         sessionFactory: @escaping (@escaping SSHHostKeyVerifier) -> SSHSession = { CitadelSession(hostKeyVerifier: $0) }) {
        self.knownHosts = SSHKnownHostsStorage.makeStore(override: knownHostsURL)
        self.sessionFactory = sessionFactory
    }

    func cancel() {
        let previous = operation
        operation = nil
        previous?.session?.disconnect()
        previous?.session = nil
    }

    func register(
        target: SSHKeyRegistrationTarget,
        privateKey: Data,
        password: String,
        approveHost: @escaping @MainActor (HostKeyFingerprint) async -> Bool,
        onProgress: @escaping @MainActor (SSHKeyRegistrationProgress) -> Void
    ) async throws -> SSHKeyRegistrationResult {
        cancel()
        try target.validate()
        guard !password.isEmpty else { throw SSHKeyRegistrationError.invalidPassword }
        let publicKey = try SSHKeyRegistrationCommand.publicKeySummary(fromPrivateKey: privateKey)
        let marker = "HYDRA_KEY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let command = try SSHKeyRegistrationCommand.make(publicKeyLine: publicKey.publicKeyLine, expectedUser: target.user, marker: marker)
        let current = Operation()
        operation = current
        defer {
            current.session?.disconnect()
            // The verifier captures this operation, so release the reverse edge
            // after disconnecting instead of retaining the completed session.
            current.session = nil
            if operation === current { operation = nil }
        }
        do {
            try progress(.checkingHost, current, onProgress)
            // Reject the first handshake deliberately. User approval can take
            // longer than SSH's authentication timeout, and needs no password.
            let probe = sessionFactory { [weak self] fingerprint in
                guard let self else { throw CancellationError() }
                try await self.capture(fingerprint, operation: current)
                throw HostProbeCaptured()
            }
            current.session = probe
            do {
                try await probe.connect(host: target.host, port: target.port, user: target.user, auth: .password(""))
                throw SSHKeyRegistrationError.registrationFailed
            } catch is HostProbeCaptured {
                // A captured key is not accepted or trusted yet.
            }
            probe.disconnect()
            current.session = nil
            try ensureCurrent(current)
            guard let fingerprint = current.fingerprint else { throw SSHKeyRegistrationError.registrationFailed }
            let entry = KnownHostsEntry(hostPattern: target.knownHostIdentity, keyType: fingerprint.keyType, publicKey: fingerprint.publicKeyBase64)
            let store = knownHosts
            switch try checkTrust(entry, store: store) {
            case .mismatch: throw SSHKeyRegistrationError.hostMismatch
            case .match: break
            case .unknown:
                try progress(.awaitingHostApproval, current, onProgress)
                let approved = await approveHost(fingerprint)
                try ensureCurrent(current)
                guard approved else { throw SSHKeyRegistrationError.hostRejected }
                // The file may have changed while the approval UI was open.
                switch try checkTrust(entry, store: store) {
                case .mismatch: throw SSHKeyRegistrationError.hostMismatch
                case .match: break
                case .unknown:
                    do {
                        try store.trust(entry)
                    } catch { throw SSHKeyRegistrationError.trustStoreUnavailable }
                }
            }
            try ensureCurrent(current)
            let verifier: SSHHostKeyVerifier = { [weak self] actual in
                guard let self else { throw CancellationError() }
                try await self.verify(actual, pinned: fingerprint, operation: current)
            }
            try progress(.connecting, current, onProgress)
            let bootstrap = sessionFactory(verifier)
            current.session = bootstrap
            try await bootstrap.connect(host: target.host, port: target.port, user: target.user, auth: .password(password))
            try ensureCurrent(current)
            guard bootstrap.remoteHostKey == fingerprint else { throw SSHKeyRegistrationError.hostMismatch }
            try progress(.registering, current, onProgress)
            // Once submitted, cancellation or transport failure cannot establish
            // whether the append happened. Never report that nothing changed.
            current.mayHaveRegistered = true
            let output = try await bootstrap.execDirect(command)
            try ensureCurrent(current)
            let alreadyRegistered: Bool
            switch output {
            case marker + ":added\n": alreadyRegistered = false
            case marker + ":exists\n": alreadyRegistered = true
            default: throw SSHKeyRegistrationError.verificationFailed(mayHaveRegistered: true)
            }
            bootstrap.disconnect()
            current.session = nil
            try progress(.verifying, current, onProgress)
            let verification = sessionFactory(verifier)
            current.session = verification
            try await verification.connect(host: target.host, port: target.port, user: target.user, auth: .privateKey(privateKey, passphrase: nil))
            try ensureCurrent(current)
            guard verification.remoteHostKey == fingerprint else {
                throw SSHKeyRegistrationError.keyLoginHostMismatch
            }
            return .init(alreadyRegistered: alreadyRegistered)
        } catch {
            if operation !== current || Task.isCancelled || error is CancellationError {
                throw SSHKeyRegistrationError.cancelled(mayHaveRegistered: current.mayHaveRegistered)
            }
            if let known = error as? SSHKeyRegistrationError {
                if current.phase == .verifying, known == .hostMismatch {
                    throw SSHKeyRegistrationError.keyLoginHostMismatch
                }
                throw known
            }
            if let cause = Self.transportFailure(error) {
                if current.phase == .verifying {
                    throw SSHKeyRegistrationError.keyLoginFailed(cause)
                }
                if current.mayHaveRegistered {
                    if case .commandFailed(let status) = cause {
                        throw SSHKeyRegistrationError.remoteCommandFailed(exitStatus: status)
                    }
                    throw SSHKeyRegistrationError.registrationInterrupted(cause)
                }
                throw SSHKeyRegistrationError.connectionFailed(cause)
            }
            if current.mayHaveRegistered {
                throw SSHKeyRegistrationError.verificationFailed(mayHaveRegistered: true)
            }
            throw SSHKeyRegistrationError.registrationFailed
        }
    }

    private func checkTrust(_ entry: KnownHostsEntry, store: KnownHostsStore) throws -> KnownHostsCheck {
        do { return try store.check(entry) }
        catch { throw SSHKeyRegistrationError.trustStoreUnavailable }
    }

    private static func transportFailure(_ error: Error) -> SSHFailure? {
        if let failure = error as? SSHFailure { return failure }
        // Compatibility for injected/older transports. Never interpret arbitrary
        // descriptions as proof that a password, network or server policy is wrong.
        guard let legacy = error as? SSHError else { return nil }
        switch legacy {
        case .authFailed: return .unknown
        case .unreachable: return .networkUnavailable
        case .handshakeFailed: return .handshakeFailed
        case .disconnected: return .connectionLost
        case .channelFailed: return .unknown
        }
    }

    private func ensureCurrent(_ current: Operation) throws {
        guard operation === current, !Task.isCancelled else {
            throw SSHKeyRegistrationError.cancelled(mayHaveRegistered: current.mayHaveRegistered)
        }
    }

    private func progress(_ value: SSHKeyRegistrationProgress, _ current: Operation,
                          _ handler: @MainActor (SSHKeyRegistrationProgress) -> Void) throws {
        try ensureCurrent(current)
        current.phase = value
        handler(value)
        try ensureCurrent(current)
    }

    private func capture(_ fingerprint: HostKeyFingerprint, operation current: Operation) throws {
        try ensureCurrent(current)
        current.fingerprint = fingerprint
    }

    private func verify(_ actual: HostKeyFingerprint, pinned: HostKeyFingerprint, operation current: Operation) throws {
        try ensureCurrent(current)
        guard actual == pinned else { throw SSHKeyRegistrationError.hostMismatch }
    }
}
