// vendored from iWorks/terminal @ 3b3545e, do not edit here
import Foundation

public enum SSHState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected(reason: String?)
}

public enum SSHError: Error, Equatable {
    case unreachable(String)
    case handshakeFailed(String)
    case authFailed(String)
    case channelFailed(String)
    case disconnected
}

public enum SSHAuth: Equatable {
    case privateKey(Data, passphrase: String?)
    case password(String)
}

public protocol SSHSession: AnyObject {
    var output: AsyncStream<Data>     { get }
    var state:  AsyncStream<SSHState> { get }

    /// Host key info returned after handshake; nil before connect.
    var remoteHostKey: HostKeyFingerprint? { get }

    func connect(host: String, port: Int, user: String,
                 auth: SSHAuth) async throws
    func openShell(termType: String, cols: Int, rows: Int) async throws
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func disconnect()

    /// Run a short command on a side channel (SSH exec / local `/bin/sh -c`)
    /// and return its stdout. Output does NOT flow through `output` — used
    /// for silent environment probes (uname, /etc/os-release, $SHELL).
    /// Implementations that don't support exec (e.g. Fake) may return "".
    func exec(_ command: String) async throws -> String
}

public extension SSHSession {
    /// Default opt-out: transports that haven't wired a side-channel return
    /// an empty string. Probe call sites must treat "" as "unknown env".
    func exec(_ command: String) async throws -> String { "" }
}

public struct HostKeyFingerprint: Equatable {
    public let keyType: String       // e.g. "ssh-ed25519"
    public let publicKeyBase64: String
    public let sha256Hex: String
    public init(keyType: String, publicKeyBase64: String, sha256Hex: String) {
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
        self.sha256Hex = sha256Hex
    }
}
