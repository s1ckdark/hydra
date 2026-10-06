import XCTest
@testable import Hydra

final class AgentRunStreamingTests: XCTestCase {
    @MainActor
    func testProgressArrivesBeforeFinalBytesAndFinalResultUsesOnePost() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel(); RunStreamProtocol.handler = nil }
        let holder = RunStreamHolder()
        RunStreamProtocol.handler = { transport in
            holder.record(transport)
            XCTAssertEqual(transport.request.url?.query, "stream=1")
            XCTAssertEqual(transport.request.httpMethod, "POST")
            XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            transport.respond(type: "text/event-stream; charset=utf-8")
            let frame = try! Self.frame(name: "progress", value: AgentRunTests.planning)
            // Intentionally withhold the final response until the callback.
            // A buffering implementation cannot complete this exchange.
            transport.push(frame.prefix(17))
            transport.push(frame.dropFirst(17))
        }
        let api = api(session)
        var observed: [String] = []
        let result: ChatResponse = try await api.chatStreaming(.init(history: [], message: "Inspect")) { snapshot in
            observed.append(snapshot.phase)
            XCTAssertEqual(snapshot.nodes.first { $0.id == "approval" }?.status, .waiting)
            let final = Data("event: chat_result\ndata: {\"type\":\"ask\",\"message\":\"done\",\"run_id\":\"run-1\"}\n\n".utf8)
            holder.transport?.push(final)
            holder.transport?.finish()
        }
        XCTAssertEqual(observed, ["awaiting_approval"])
        XCTAssertEqual(result.runID, "run-1")
        XCTAssertEqual(result.message, "done")
        XCTAssertEqual(holder.requestCount, 1)
    }

    @MainActor
    func testOldServerJSONFallbackDoesNotReplayExecuteOrFabricateProgress() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel(); RunStreamProtocol.handler = nil }
        let holder = RunStreamHolder()
        RunStreamProtocol.handler = { transport in
            holder.record(transport)
            XCTAssertEqual(transport.request.url?.path, "/api/agent/execute")
            XCTAssertEqual(transport.request.timeoutInterval, 130)
            let body = try! Self.body(transport.request)
            XCTAssertEqual(body["run_id"] as? String, "run-1")
            let selection = body["model_selection"] as? [String: Any]
            XCTAssertEqual(selection?["team_revision"] as? String, "revision-1")
            transport.respond(type: "application/json")
            transport.push(Data(#"{"results":[],"summary":"done"}"#.utf8))
            transport.finish()
        }
        var progressCount = 0
        let result = try await api(session).executePlanStreaming(.init(intent: "Inspect", actions: []),
                                                                 modelSelection: Self.selection, runID: "run-1") { _ in progressCount += 1 }
        XCTAssertEqual(result.summary, "done")
        XCTAssertEqual(progressCount, 0)
        XCTAssertEqual(holder.requestCount, 1)
    }

    @MainActor
    func testEOFAndErrorEventsDoNotCountAsFinalSuccessOrRetry() async throws {
        for payload in ["event: progress\ndata: {\"run_id\":\"run-1\",\"phase\":\"completed\",\"nodes\":[],\"edges\":[]}\n\n",
                        "event: error\ndata: {\"error\":\"safe provider failure\"}\n\n",
                        "event: execute_result\ndata: {\"results\":[]}\n"] {
            let session = makeSession()
            let holder = RunStreamHolder()
            RunStreamProtocol.handler = { transport in
                holder.record(transport)
                transport.respond(type: "text/event-stream")
                transport.push(Data(payload.utf8))
                transport.finish()
            }
            do {
                _ = try await api(session).executePlanStreaming(.init(intent: "Inspect", actions: []),
                                                                modelSelection: nil, runID: nil) { _ in }
                XCTFail("Only a complete execute_result may succeed")
            } catch is AgentStreamError { }
            XCTAssertEqual(holder.requestCount, 1)
            session.invalidateAndCancel()
        }
        RunStreamProtocol.handler = nil
    }

    @MainActor
    func testRunContinuityMergesHeadAndCapturesSelectionThroughApproval() async {
        let client = StreamingRunClient()
        let vm = ChatViewModel(api: client, instructionProvider: { nil })
        vm.selectAgent(Self.target)
        client.onPlanningProgress = {
            XCTAssertTrue(vm.isThinking)
            XCTAssertNil(vm.pendingPlan)
            XCTAssertNotNil(vm.agentRun)
        }
        await vm.send("Inspect")
        XCTAssertEqual(vm.pendingRunID, "run-1")
        XCTAssertTrue(client.executions.isEmpty)
        client.onExecutionProgress = {
            XCTAssertEqual(vm.agentRun?.nodes.first { $0.id == "head" }?.status, .completed)
            XCTAssertEqual(vm.agentRun?.nodes.first { $0.id == "action-0" }?.status, .running)
        }
        await vm.runPendingPlan()
        XCTAssertEqual(client.executions.count, 1)
        XCTAssertEqual(client.executions.first?.0, "run-1")
        XCTAssertEqual(client.executions.first?.1, Self.selection)
        XCTAssertEqual(vm.agentRun?.phase, "completed")
        XCTAssertEqual(vm.agentRun?.nodes.first { $0.id == "head" }?.status, .completed)
        XCTAssertNil(vm.pendingPlan)
        XCTAssertNil(vm.pendingRunID)
    }

    @MainActor
    func testCancelAndNewChatIgnoreStaleCallbacksAndDoNotExecute() async {
        let client = StreamingRunClient()
        let vm = ChatViewModel(api: client, instructionProvider: { nil })
        vm.selectAgent(Self.target)
        await vm.send("Inspect")
        let stale = client.chatCallback
        vm.cancelPendingPlan()
        XCTAssertEqual(vm.agentRun?.phase, "cancelled")
        XCTAssertEqual(vm.agentRun?.nodes.first { $0.id == "action-0" }?.status, .skipped)
        XCTAssertTrue(client.executions.isEmpty)
        client.nextRunID = "run-2"
        client.onPlanningProgress = {
            XCTAssertFalse(vm.agentRun?.nodes.contains { $0.id == "head" } ?? true,
                           "The next chat must start with only its fresh progress")
        }
        client.onlyFirstPlanningNode = true
        await vm.send("Another request")
        XCTAssertEqual(vm.agentRun?.runID, "run-2")
        await stale?(AgentRunTests.planning)
        XCTAssertEqual(vm.agentRun?.runID, "run-2")
        XCTAssertTrue(client.executions.isEmpty)
    }

    @MainActor
    func testDisconnectedExecuteRetainsEvidenceAndCannotReplayPendingPlan() async {
        let client = StreamingRunClient()
        client.failExecution = true
        let vm = ChatViewModel(api: client, instructionProvider: { nil })
        vm.selectAgent(Self.target)
        await vm.send("Inspect")
        await vm.runPendingPlan()
        XCTAssertTrue(vm.progressDisconnected)
        XCTAssertEqual(vm.agentRun?.nodes.first { $0.id == "head" }?.status, .completed)
        XCTAssertEqual(vm.agentRun?.nodes.first { $0.id == "action-0" }?.status, .unknown)
        XCTAssertNil(vm.pendingPlan)
        XCTAssertNotNil(vm.error)
        await vm.runPendingPlan()
        XCTAssertEqual(client.executions.count, 1)
    }

    @MainActor
    func testConfirmedServerFailuresPreserveTerminalTreeWithoutDisconnectBanner() async {
        for phase in ["failed", "cancelled"] {
            let client = StreamingRunClient()
            let vm = ChatViewModel(api: client, instructionProvider: { nil })
            vm.selectAgent(Self.target)
            client.failChatPhase = phase
            await vm.send("Inspect")
            XCTAssertEqual(vm.agentRun?.phase, phase)
            XCTAssertFalse(vm.progressDisconnected)
            XCTAssertNil(vm.pendingPlan)
            client.failChatPhase = nil
            await vm.send("Inspect again")
            client.failExecutionPhase = phase
            await vm.runPendingPlan()
            XCTAssertEqual(vm.agentRun?.phase, phase)
            XCTAssertFalse(vm.progressDisconnected)
            XCTAssertNil(vm.pendingPlan)
            await vm.runPendingPlan()
            XCTAssertEqual(client.executions.count, 1)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunStreamProtocol.self]
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }

    private func api(_ session: URLSession) -> APIClient {
        APIClient(baseURL: URL(string: "https://fixture.invalid")!, session: session, apiKeyProvider: { "fixture-token" })
    }

    private static func frame<T: Encodable>(name: String, value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return Data("event: \(name)\ndata: ".utf8) + (try encoder.encode(value)) + Data("\n\n".utf8)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static let selection = AgentModelSelection(orchestrationID: "orch", agentID: "agent", connectionID: "connection", provider: "openai", model: "exact", source: "head", reason: nil, teamRevision: "revision-1")
    private static let target = AgentChatTarget(orchestrationID: "orch", orchestrationName: "Fixture", agent: .init(id: "agent", name: "Reviewer", role: "Review"), modelLabel: nil)
}

@MainActor
private final class StreamingRunClient: ChatClient {
    var nextRunID = "run-1"
    var onlyFirstPlanningNode = false
    var failExecution = false
    var failChatPhase: String?
    var failExecutionPhase: String?
    var executions: [(String?, AgentModelSelection?)] = []
    var chatCallback: AgentProgressHandler?
    var onPlanningProgress: (() -> Void)?
    var onExecutionProgress: (() -> Void)?

    func chat(_ request: ChatRequest) async throws -> ChatResponse { fatalError("Streaming entry point expected") }
    func executePlan(_ plan: AgentPlan, modelSelection: AgentModelSelection?) async throws -> AgentExecuteResponse { fatalError("Streaming entry point expected") }

    func chatStreaming(_ request: ChatRequest, onProgress: @escaping AgentProgressHandler) async throws -> ChatResponse {
        chatCallback = onProgress
        let planning = AgentRunTests.planning
        let snapshot = AgentRunSnapshot(runID: nextRunID, phase: planning.phase,
                                         nodes: onlyFirstPlanningNode ? Array(planning.nodes.prefix(1)) : planning.nodes,
                                         edges: onlyFirstPlanningNode ? [] : planning.edges)
        await onProgress(snapshot)
        onPlanningProgress?()
        if let phase = failChatPhase {
            var failed = snapshot
            failed.phase = phase
            for index in failed.nodes.indices { failed.nodes[index].status = phase == "cancelled" ? .cancelled : .failed }
            await onProgress(failed)
            throw AgentStreamError.server("Fixture failure")
        }
        return ChatResponse(type: "plan", message: "Inspect", plan: .init(intent: "Inspect", actions: []),
                            modelSelection: AgentRunStreamingTests.selection, runID: nextRunID)
    }

    func executePlanStreaming(_ plan: AgentPlan, modelSelection: AgentModelSelection?, runID: String?,
                              onProgress: @escaping AgentProgressHandler) async throws -> AgentExecuteResponse {
        executions.append((runID, modelSelection))
        await onProgress(AgentRunTests.executing)
        onExecutionProgress?()
        if failExecution { throw AgentStreamError.incomplete }
        if let phase = failExecutionPhase {
            var failed = AgentRunTests.executing
            failed.phase = phase
            for index in failed.nodes.indices { failed.nodes[index].status = phase == "cancelled" ? .cancelled : .failed }
            await onProgress(failed)
            throw AgentStreamError.server("Fixture failure")
        }
        var completed = AgentRunTests.executing
        completed.phase = "completed"
        for index in completed.nodes.indices { completed.nodes[index].status = .completed }
        await onProgress(completed)
        return AgentExecuteResponse(results: [], summary: "Done", runID: runID)
    }
}

private final class RunStreamHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RunStreamProtocol?
    private var count = 0
    var transport: RunStreamProtocol? { lock.lock(); defer { lock.unlock() }; return stored }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func record(_ transport: RunStreamProtocol) { lock.lock(); defer { lock.unlock() }; stored = transport; count += 1 }
}

private final class RunStreamProtocol: URLProtocol {
    static var handler: ((RunStreamProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(type: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func push(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
}
