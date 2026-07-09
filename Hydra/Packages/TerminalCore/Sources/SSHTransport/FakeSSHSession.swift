// vendored from iWorks/terminal @ 3b3545e, do not edit here
import Foundation

/// Loopback echo session for development and previews.
public final class FakeSSHSession: SSHSession {

    public let output: AsyncStream<Data>
    public let state:  AsyncStream<SSHState>

    private let outputContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation:  AsyncStream<SSHState>.Continuation

    public var remoteHostKey: HostKeyFingerprint? {
        HostKeyFingerprint(
            keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAFAKE",
            sha256Hex: String(repeating: "00", count: 32))
    }

    public init() {
        var oc: AsyncStream<Data>.Continuation!
        output = AsyncStream { oc = $0 }
        outputContinuation = oc

        var sc: AsyncStream<SSHState>.Continuation!
        state = AsyncStream { sc = $0 }
        stateContinuation = sc
    }

    public func connect(host: String, port: Int, user: String,
                        auth: SSHAuth) async throws {
        stateContinuation.yield(.connecting)
        try await Task.sleep(nanoseconds: 100_000_000)
        stateContinuation.yield(.connected)
    }

    public func openShell(termType: String, cols: Int, rows: Int) async throws {
        outputContinuation.yield(Data("fake$ ".utf8))
    }

    public func write(_ data: Data) async throws {
        // Local echo with CR→CRLF + new prompt rewrite so the screen looks like a real shell.
        var out = Data()
        for byte in data {
            switch byte {
            case 0x0D:                      // CR (Enter) → CRLF + new prompt
                out.append(contentsOf: [0x0D, 0x0A])
                out.append(contentsOf: Data("fake$ ".utf8))
            case 0x7F:                      // DEL (Backspace) → BS + space + BS to erase
                out.append(contentsOf: [0x08, 0x20, 0x08])
            case 0x03:                      // Ctrl-C → ^C + CRLF + new prompt
                out.append(contentsOf: Data("^C".utf8))
                out.append(contentsOf: [0x0D, 0x0A])
                out.append(contentsOf: Data("fake$ ".utf8))
            default:
                out.append(byte)
            }
        }
        outputContinuation.yield(out)
    }

    public func resize(cols: Int, rows: Int) async throws {}

    public func exec(_ command: String) async throws -> String {
        // No real shell; return a recognizable fake so probes don't fail.
        return "fake-os\nfake-shell"
    }

    public func disconnect() {
        stateContinuation.yield(.disconnected(reason: nil))
        outputContinuation.finish()
        stateContinuation.finish()
    }
}
