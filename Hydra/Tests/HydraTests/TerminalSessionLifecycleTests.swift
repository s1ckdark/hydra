#if os(macOS)
import Combine
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

@MainActor
final class TerminalSessionLifecycleTests: XCTestCase {
    private func makeTerminal(backends: [LifecycleSSHSession], persistence: Bool = false) throws -> TerminalSession {
        var remaining = backends
        let knownHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-lifecycle-\(UUID().uuidString)")
        try KnownHostsStore(fileURL: knownHostsURL).trust(
            HostKeyGate.entry(host: "100.0.0.1", fingerprint: LifecycleSSHSession.fingerprint))
        addTeardownBlock { try? FileManager.default.removeItem(at: knownHostsURL) }
        let device = Device(id: "lifecycle", name: "lifecycle", hostname: "lifecycle",
                            ipAddresses: [], tailscaleIp: "100.0.0.1", os: "Linux",
                            status: "online", isExternal: false, tags: nil, user: "test",
                            lastSeen: Date(), sshEnabled: true, hasGpu: false,
                            gpuModel: nil, gpuCount: 0)
        return TerminalSession(device: device,
            sessionFactory: { remaining.removeFirst() },
            knownHostsURL: knownHostsURL,
            credentialResolver: {
                SSHCredentials(user: "test", port: 22,
                    keys: [.init(path: "test-key", pem: Data(), algorithm: "ed25519")])
            }, persistenceEnabled: { persistence })
    }

    func testStaleOpenShellFailureDoesNotDisconnectNewConnection() async throws {
        let oldShellStarted = expectation(description: "old shell request suspended")
        let oldShellGate = LifecycleGate()
        let oldBackend = LifecycleSSHSession(onOpenShell: {
            oldShellStarted.fulfill()
            await oldShellGate.wait()
            throw SSHError.channelFailed("old shell failed late")
        })
        let newBackend = LifecycleSSHSession()
        let terminal = try makeTerminal(backends: [oldBackend, newBackend])
        defer { terminal.close() }
        let oldConnection = Task { await terminal.connect(cols: 80, rows: 24) }
        await fulfillment(of: [oldShellStarted], timeout: 3)

        let newConnected = expectation(description: "new connection state observed")
        let subscription = terminal.$state.dropFirst().filter { $0 == .connected }.prefix(1)
            .sink { _ in newConnected.fulfill() }
        await terminal.connect(cols: 120, rows: 40)
        await fulfillment(of: [newConnected], timeout: 3)
        await oldShellGate.open()
        await oldConnection.value

        XCTAssertEqual(terminal.state, .connected,
                       "an earlier shell failure must not overwrite the current connection state")
        withExtendedLifetime(subscription) {}
    }

    func testCloseDuringOpenShellPreventsPendingResizeAndBootstrap() async throws {
        let shellStarted = expectation(description: "shell request suspended before close")
        let promptObserved = expectation(description: "prompt reached current output pump")
        let initialResize = expectation(description: "requested size recorded before close")
        let shellGate = LifecycleGate()
        let backend = LifecycleSSHSession(onOpenShell: {
            shellStarted.fulfill()
            await shellGate.wait()
        }, onResize: { _, _ in initialResize.fulfill() })
        let terminal = try makeTerminal(backends: [backend], persistence: true)
        terminal.onOutput = { _ in promptObserved.fulfill() }
        let connecting = Task { await terminal.connect(cols: 80, rows: 24) }
        await fulfillment(of: [shellStarted, promptObserved], timeout: 3)
        terminal.resize(cols: 120, rows: 40)
        await fulfillment(of: [initialResize], timeout: 3)
        backend.onResize = nil

        terminal.close()
        await shellGate.open()
        await connecting.value

        XCTAssertEqual(backend.operationsAfterDisconnect, [],
                       "a completed stale shell must not resize or inject tmux after close")
    }

    func testReconnectDoesNotReplayOldShellResizeOntoNewBackend() async throws {
        let oldShellStarted = expectation(description: "old shell request suspended")
        let initialResize = expectation(description: "initial requested size reached old backend")
        let oldShellGate = LifecycleGate()
        let oldBackend = LifecycleSSHSession(onOpenShell: {
            oldShellStarted.fulfill()
            await oldShellGate.wait()
        }, onResize: { _, _ in initialResize.fulfill() })
        let newBackend = LifecycleSSHSession()
        let terminal = try makeTerminal(backends: [oldBackend, newBackend])
        defer { terminal.close() }
        let oldConnection = Task { await terminal.connect(cols: 80, rows: 24) }
        await fulfillment(of: [oldShellStarted], timeout: 3)
        terminal.resize(cols: 120, rows: 40)
        await fulfillment(of: [initialResize], timeout: 3)

        await terminal.connect(cols: 100, rows: 30)
        XCTAssertEqual(newBackend.operations, [.openShell, .resize(120, 40)])
        await oldShellGate.open()
        await oldConnection.value

        XCTAssertEqual(newBackend.operations, [.openShell, .resize(120, 40)],
                       "only the new shell may reapply the latest requested size")
    }
}

private actor LifecycleGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class LifecycleSSHSession: SSHSession {
    enum Operation: Equatable {
        case openShell
        case resize(Int, Int)
        case write(Data)
        case disconnect
    }

    static let fingerprint = HostKeyFingerprint(keyType: "ssh-ed25519",
        publicKeyBase64: "AAAALIFECYCLETEST", sha256Hex: "lifecycle-test")
    let output: AsyncStream<Data>
    let state: AsyncStream<SSHState>
    let remoteHostKey: HostKeyFingerprint? = fingerprint
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<SSHState>.Continuation
    private let onOpenShell: (() async throws -> Void)?
    var onResize: ((Int, Int) -> Void)?
    private let lock = NSLock()
    private var recorded: [Operation] = []

    var operations: [Operation] { lock.withLock { recorded } }
    var operationsAfterDisconnect: [Operation] {
        lock.withLock {
            guard let index = recorded.firstIndex(of: .disconnect) else { return [] }
            return Array(recorded.dropFirst(index + 1))
        }
    }

    init(onOpenShell: (() async throws -> Void)? = nil,
         onResize: ((Int, Int) -> Void)? = nil) {
        self.onOpenShell = onOpenShell
        self.onResize = onResize
        (output, outputContinuation) = AsyncStream<Data>.makeStream()
        (state, stateContinuation) = AsyncStream<SSHState>.makeStream()
    }

    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {
        stateContinuation.yield(.connected)
    }

    func openShell(termType: String, cols: Int, rows: Int) async throws {
        lock.withLock { recorded.append(.openShell) }
        outputContinuation.yield(Data("lifecycle$ ".utf8))
        try await onOpenShell?()
    }

    func resize(cols: Int, rows: Int) async throws {
        lock.withLock { recorded.append(.resize(cols, rows)) }
        onResize?(cols, rows)
    }

    func write(_ data: Data) async throws {
        lock.withLock { recorded.append(.write(data)) }
    }

    func disconnect() {
        lock.withLock { recorded.append(.disconnect) }
        stateContinuation.yield(.disconnected(reason: nil))
        stateContinuation.finish()
        outputContinuation.finish()
    }
}
#endif
