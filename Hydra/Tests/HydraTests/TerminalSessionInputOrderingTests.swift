#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

@MainActor
final class TerminalSessionInputOrderingTests: XCTestCase {
    private func makeTerminal(backends: [BlockingInputSSHSession], keyCount: Int = 1) -> TerminalSession {
        var remaining = backends
        let knownHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-input-order-\(UUID().uuidString)")
        try? KnownHostsStore(fileURL: knownHostsURL).trust(
            HostKeyGate.entry(host: "100.0.0.1", fingerprint: BlockingInputSSHSession.fingerprint))
        addTeardownBlock { try? FileManager.default.removeItem(at: knownHostsURL) }
        let device = Device(id: "input-order", name: "input-order", hostname: "input-order",
                            ipAddresses: [], tailscaleIp: "100.0.0.1", os: "Linux",
                            status: "online", isExternal: false, tags: nil, user: "test",
                            lastSeen: Date(), sshEnabled: true, hasGpu: false,
                            gpuModel: nil, gpuCount: 0)
        return TerminalSession(device: device,
            sessionFactory: { remaining.removeFirst() },
            knownHostsURL: knownHostsURL,
            credentialResolver: {
                SSHCredentials(user: "test", port: 22,
                    keys: (0..<keyCount).map {
                        .init(path: "test-key-\($0)", pem: Data(), algorithm: "ed25519")
                    })
            },
            persistenceEnabled: { false })
    }

    func testReturnWaitsForPendingCommittedKoreanText() async {
        let backend = BlockingInputSSHSession()
        let terminal = makeTerminal(backends: [backend])
        defer { terminal.close() }
        await terminal.connect(cols: 80, rows: 24)
        let text = Data("어떨까?".utf8)
        let carriageReturn = Data([0x0d])
        let textStarted = expectation(description: "committed text entered transport")
        let completed = expectation(description: "both writes completed")
        completed.expectedFulfillmentCount = 2
        backend.recorder.onStarted = { if $0 == text { textStarted.fulfill() } }
        backend.recorder.onCompleted = { _ in completed.fulfill() }

        terminal.send(text)
        await fulfillment(of: [textStarted], timeout: 3)
        terminal.send(carriageReturn)
        // The transport has explicitly suspended the text write. Release its
        // gate and verify actual entry/completion order, not elapsed time.
        await backend.gate.open()
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(backend.recorder.events,
                       [.started(text), .completed(text),
                        .started(carriageReturn), .completed(carriageReturn)])
        XCTAssertEqual(backend.recorder.maximumConcurrentWrites, 1)
    }

    func testBurstKeepsChunkAndByteOrderWithOnlyOneInFlightWrite() async {
        let backend = BlockingInputSSHSession()
        let terminal = makeTerminal(backends: [backend])
        defer { terminal.close() }
        await terminal.connect(cols: 80, rows: 24)
        let chunks = (0..<128).map { Data("\($0):어떨까?\r".utf8) }
        let firstStarted = expectation(description: "first burst write is blocked")
        let completed = expectation(description: "all burst writes completed")
        completed.expectedFulfillmentCount = chunks.count
        backend.recorder.onStarted = { if $0 == chunks[0] { firstStarted.fulfill() } }
        backend.recorder.onCompleted = { _ in completed.fulfill() }

        terminal.send(chunks[0])
        await fulfillment(of: [firstStarted], timeout: 3)
        for chunk in chunks.dropFirst() { terminal.send(chunk) }
        await backend.gate.open()
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(backend.recorder.events,
                       chunks.flatMap { [.started($0), .completed($0)] })
        XCTAssertEqual(backend.recorder.maximumConcurrentWrites, 1)
    }

    func testCloseDiscardsQueuedInputBeforeReconnect() async {
        await assertQueuedInputDiscarded(closeFirst: true)
    }

    func testReconnectDiscardsQueuedInputWithoutExplicitClose() async {
        await assertQueuedInputDiscarded(closeFirst: false)
    }

    func testDeinitDiscardsQueuedInputAndReleasesWriterWithoutClose() async {
        let backendReleased = expectation(description: "unconnected backend and writer released")
        var backend: BlockingInputSSHSession? = BlockingInputSSHSession()
        backend?.onDeinit = { backendReleased.fulfill() }
        let recorder = backend!.recorder
        let gate = backend!.gate
        var terminal: TerminalSession? = makeTerminal(backends: [backend!])
        let started = expectation(description: "write blocked before deinit")
        let text = Data("in-flight".utf8)
        recorder.onStarted = { if $0 == text { started.fulfill() } }
        terminal?.send(text)
        await fulfillment(of: [started], timeout: 3)
        terminal?.send(Data("discard-on-deinit".utf8))

        backend = nil
        terminal = nil
        await gate.open()
        await fulfillment(of: [backendReleased], timeout: 3)
        XCTAssertEqual(recorder.events, [.started(text), .completed(text)])
    }

    func testStaleAuthenticationFailureDoesNotCancelNewConnectionWriter() async {
        let authenticationStarted = expectation(description: "old authentication suspended")
        let authenticationGate = InputWriteGate()
        let oldBackend = BlockingInputSSHSession(onConnect: {
            authenticationStarted.fulfill()
            await authenticationGate.wait()
            throw SSHError.authFailed("old attempt")
        })
        let newBackend = BlockingInputSSHSession()
        let terminal = makeTerminal(backends: [oldBackend, newBackend])
        defer { terminal.close() }
        let oldConnect = Task { await terminal.connect(cols: 80, rows: 24) }
        await fulfillment(of: [authenticationStarted], timeout: 3)

        await terminal.connect(cols: 80, rows: 24)
        await authenticationGate.open()
        await oldConnect.value
        let completed = expectation(description: "new writer survived stale catch")
        newBackend.recorder.onCompleted = { _ in completed.fulfill() }
        let text = Data("어떨까?\r".utf8)
        terminal.send(text)
        await newBackend.gate.open()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(newBackend.recorder.events, [.started(text), .completed(text)])
    }

    func testCloseDuringAuthenticationPreventsFallbackWriterResurrection() async {
        let authenticationStarted = expectation(description: "authentication suspended before close")
        let authenticationGate = InputWriteGate()
        let oldBackend = BlockingInputSSHSession(onConnect: {
            authenticationStarted.fulfill()
            await authenticationGate.wait()
            throw SSHError.authFailed("closed attempt")
        })
        let fallbackBackend = BlockingInputSSHSession()
        let terminal = makeTerminal(backends: [oldBackend, fallbackBackend], keyCount: 2)
        let connecting = Task { await terminal.connect(cols: 80, rows: 24) }
        await fulfillment(of: [authenticationStarted], timeout: 3)

        terminal.close()
        await authenticationGate.open()
        await connecting.value
        XCTAssertEqual(fallbackBackend.recorder.connectCount, 0,
                       "a closed authentication attempt must not create its next backend/writer")
    }

    func testAuthenticationFallbackDiscardsFailedAttemptInput() async {
        let authenticationStarted = expectation(description: "first key authentication suspended")
        let authenticationGate = InputWriteGate()
        let oldReleased = expectation(description: "failed key backend released")
        var oldBackend: BlockingInputSSHSession? = BlockingInputSSHSession(onConnect: {
            authenticationStarted.fulfill()
            await authenticationGate.wait()
            throw SSHError.authFailed("try next key")
        })
        oldBackend?.onDeinit = { oldReleased.fulfill() }
        let oldRecorder = oldBackend!.recorder
        let oldGate = oldBackend!.gate
        let newBackend = BlockingInputSSHSession()
        let terminal = makeTerminal(backends: [oldBackend!, newBackend], keyCount: 2)
        defer { terminal.close() }
        let connecting = Task { await terminal.connect(cols: 80, rows: 24) }
        await fulfillment(of: [authenticationStarted], timeout: 3)
        let started = expectation(description: "failed key write suspended")
        let oldText = Data("first-attempt".utf8)
        oldRecorder.onStarted = { if $0 == oldText { started.fulfill() } }
        terminal.send(oldText)
        await fulfillment(of: [started], timeout: 3)
        terminal.send(Data("discard-failed-attempt".utf8))

        await authenticationGate.open()
        await connecting.value
        let completed = expectation(description: "fallback key writer delivered new text")
        newBackend.recorder.onCompleted = { _ in completed.fulfill() }
        let newText = Data("어떨까?\r".utf8)
        terminal.send(newText)
        await newBackend.gate.open()
        await fulfillment(of: [completed], timeout: 3)
        oldBackend = nil
        await oldGate.open()
        await fulfillment(of: [oldReleased], timeout: 3)
        XCTAssertEqual(oldRecorder.events, [.started(oldText), .completed(oldText)])
        XCTAssertEqual(newBackend.recorder.events, [.started(newText), .completed(newText)])
    }

    private func assertQueuedInputDiscarded(closeFirst: Bool) async {
        let oldReleased = expectation(description: "retired backend and writer released")
        var oldBackend: BlockingInputSSHSession? = BlockingInputSSHSession()
        oldBackend?.onDeinit = { oldReleased.fulfill() }
        let oldRecorder = oldBackend!.recorder
        let oldGate = oldBackend!.gate
        let newBackend = BlockingInputSSHSession()
        let terminal = makeTerminal(backends: [oldBackend!, newBackend])
        defer { terminal.close() }
        await terminal.connect(cols: 80, rows: 24)
        let inFlight = Data("old-in-flight".utf8)
        let newText = Data("새 세션 어떨까?\r".utf8)
        let oldStarted = expectation(description: "old write is blocked")
        let newCompleted = expectation(description: "new session input delivered")
        oldRecorder.onStarted = { if $0 == inFlight { oldStarted.fulfill() } }
        newBackend.recorder.onCompleted = { _ in newCompleted.fulfill() }

        terminal.send(inFlight)
        await fulfillment(of: [oldStarted], timeout: 3)
        terminal.send(Data("discard-queued-text".utf8))
        terminal.send(Data([0x0d]))
        if closeFirst {
            terminal.close()
            terminal.send(Data("discard-after-close".utf8))
        }
        await terminal.connect(cols: 80, rows: 24)
        terminal.send(newText)
        await newBackend.gate.open()
        await fulfillment(of: [newCompleted], timeout: 3)

        // This fake deliberately ignores cancellation while its first write is
        // suspended. Backend deallocation proves the old worker has finished,
        // so the final assertion cannot race a later drain of its queued data.
        oldBackend = nil
        await oldGate.open()
        await fulfillment(of: [oldReleased], timeout: 3)
        XCTAssertEqual(oldRecorder.events, [.started(inFlight), .completed(inFlight)])
        XCTAssertEqual(newBackend.recorder.events, [.started(newText), .completed(newText)])
    }
}

private actor InputWriteGate {
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

private final class InputWriteRecorder {
    enum Event: Equatable { case started(Data), completed(Data) }
    private let lock = NSLock()
    private var recorded: [Event] = []
    private var activeWrites = 0
    private var maxActiveWrites = 0
    private var connects = 0
    var onStarted: ((Data) -> Void)?
    var onCompleted: ((Data) -> Void)?

    var events: [Event] { lock.withLock { recorded } }
    var maximumConcurrentWrites: Int { lock.withLock { maxActiveWrites } }
    var connectCount: Int { lock.withLock { connects } }

    func connected() { lock.withLock { connects += 1 } }

    func started(_ data: Data) {
        lock.withLock {
            recorded.append(.started(data))
            activeWrites += 1
            maxActiveWrites = max(maxActiveWrites, activeWrites)
        }
        onStarted?(data)
    }

    func completed(_ data: Data) {
        lock.withLock {
            recorded.append(.completed(data))
            activeWrites -= 1
        }
        onCompleted?(data)
    }
}

private final class BlockingInputSSHSession: SSHSession {
    static let fingerprint = HostKeyFingerprint(keyType: "ssh-ed25519",
        publicKeyBase64: "AAAAINPUTTEST", sha256Hex: "input-test")
    let gate = InputWriteGate()
    let recorder = InputWriteRecorder()
    var onDeinit: (() -> Void)?
    let output: AsyncStream<Data>
    let state: AsyncStream<SSHState>
    let remoteHostKey: HostKeyFingerprint? = fingerprint
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<SSHState>.Continuation
    private let onConnect: (() async throws -> Void)?

    init(onConnect: (() async throws -> Void)? = nil) {
        self.onConnect = onConnect
        (output, outputContinuation) = AsyncStream<Data>.makeStream()
        (state, stateContinuation) = AsyncStream<SSHState>.makeStream()
    }

    deinit { onDeinit?() }

    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {
        recorder.connected()
        try await onConnect?()
        stateContinuation.yield(.connected)
    }
    func openShell(termType: String, cols: Int, rows: Int) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func write(_ data: Data) async throws {
        recorder.started(data)
        await gate.wait()
        recorder.completed(data)
    }
    func disconnect() {
        stateContinuation.yield(.disconnected(reason: nil))
        stateContinuation.finish()
        outputContinuation.finish()
    }
}
#endif
