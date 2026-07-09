#if os(macOS)
import Foundation
import SSHTransport

/// Test double whose connect() outcome is scripted per instance, so a factory
/// can hand TerminalSession a fresh scripted session per key attempt. (Vendored
/// FakeSSHSession is "do not edit" and always auth-succeeds, so it can't drive
/// the fallback loop.)
final class ScriptedSSHSession: SSHSession {
    enum Outcome { case authFail; case succeed(HostKeyFingerprint?); case unreachable }
    let outcome: Outcome
    private(set) var connectCalled = false
    private(set) var openShellCalled = false

    let output: AsyncStream<Data>
    let state: AsyncStream<SSHState>
    private let oc: AsyncStream<Data>.Continuation
    private let sc: AsyncStream<SSHState>.Continuation
    private(set) var remoteHostKey: HostKeyFingerprint?

    init(_ outcome: Outcome) {
        self.outcome = outcome
        var o: AsyncStream<Data>.Continuation!; output = AsyncStream { o = $0 }; oc = o
        var s: AsyncStream<SSHState>.Continuation!; state = AsyncStream { s = $0 }; sc = s
    }
    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {
        connectCalled = true
        sc.yield(.connecting)
        switch outcome {
        case .authFail:    throw SSHError.authFailed("scripted-auth-fail")
        case .unreachable: throw SSHError.unreachable("scripted-unreachable")
        case .succeed(let hk): remoteHostKey = hk; sc.yield(.connected)
        }
    }
    func openShell(termType: String, cols: Int, rows: Int) async throws {
        openShellCalled = true
        oc.yield(Data("scripted$ ".utf8))
    }
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func exec(_ command: String) async throws -> String { "" }
    func disconnect() { sc.yield(.disconnected(reason: nil)); oc.finish(); sc.finish() }
}
#endif
