import XCTest
@testable import Hydra

final class OrchAIAgentsTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testLegacyChatPayloadsRemainCompatibleAndOptionalKeysAreOmitted() throws {
        let response = try decoder.decode(ChatResponse.self, from: Data(#"{"type":"ask","message":"hello","plan":null}"#.utf8))
        XCTAssertNil(response.modelSelection)
        let turn = try decoder.decode(ChatTurn.self, from: Data(#"{"role":"user","content":"hello"}"#.utf8))
        XCTAssertNil(turn.modelSelection)
        let chat = try object(ChatRequest(history: [], message: "hello"))
        XCTAssertEqual(Set(chat.keys), ["history", "message"])
        let execute = try object(AgentExecuteRequest(plan: AgentPlan(intent: "inspect", actions: [])))
        XCTAssertEqual(Set(execute.keys), ["plan"])
        let selection = try decoder.decode(AgentModelSelection.self, from: Data(#"{"orchestration_id":"o","agent_id":"a","connection_id":"c","provider":"openai","model":"exact","source":"head"}"#.utf8))
        XCTAssertNil(selection.teamRevision)
    }

    func testSelectionAndTargetUseExactWireKeysAndKeepModelVersion() throws {
        let selection = Self.selection
        let chat = try object(ChatRequest(history: [], message: "hello", orchestrationID: "orch", agentID: "agent"))
        XCTAssertEqual(chat["orchestration_id"] as? String, "orch")
        XCTAssertEqual(chat["agent_id"] as? String, "agent")
        XCTAssertNil(chat["orchestrationID"])
        let execute = try object(AgentExecuteRequest(plan: .init(intent: "inspect", actions: []), modelSelection: selection))
        let encoded = try XCTUnwrap(execute["model_selection"] as? [String: Any])
        XCTAssertEqual(encoded["connection_id"] as? String, "connection")
        XCTAssertEqual(encoded["model"] as? String, "exact-model-version")
        XCTAssertEqual(encoded["team_revision"] as? String, "revision-1")
        XCTAssertEqual(try decoder.decode(AgentExecuteRequest.self, from: encoder.encode(AgentExecuteRequest(plan: .init(intent: "inspect", actions: []), modelSelection: selection))).modelSelection, selection)
    }

    func testMaskedKeysAreNeverReconstructedOrResubmitted() throws {
        let masked = Data(#"{"connections":[{"id":"c","name":"Cloud","provider":"claude","endpoint":"","models":["model-1","model-2"],"has_api_key":true,"api_key":"redacted"}],"head_model":null,"agents":[]}"#.utf8)
        var team = try decoder.decode(OrchAIAgents.self, from: masked)
        XCTAssertTrue(team.connections[0].hasAPIKey)
        XCTAssertNil(team.connections[0].apiKey)
        var connection = try XCTUnwrap((try object(team)["connections"] as? [[String: Any]])?.first)
        XCTAssertNil(connection["api_key"])
        XCTAssertNil(connection["has_api_key"])
        team.connections[0].apiKey = "fixture-only-new-key"
        connection = try XCTUnwrap((try object(team)["connections"] as? [[String: Any]])?.first)
        XCTAssertEqual(connection["api_key"] as? String, "fixture-only-new-key")
        team.connections[0].apiKey = "  "
        connection = try XCTUnwrap((try object(team)["connections"] as? [[String: Any]])?.first)
        XCTAssertNil(connection["api_key"])
    }

    func testStoredKeyRequiresAnUnchangedConnectionIdentity() {
        let original = OrchAIAgents(connections: [.init(id: "c", name: "Cloud", provider: "openai", models: ["exact"], hasAPIKey: true)])
        var draft = original
        XCTAssertTrue(draft.validationErrors(original: original).isEmpty)
        draft.connections[0].name = "Renamed"
        draft.connections[0].models.append("another-exact-version")
        XCTAssertTrue(draft.validationErrors(original: original).isEmpty)
        for changed in [OrchAIConnection(id: "new", name: "Cloud", provider: "openai", models: ["exact"], hasAPIKey: true),
                        OrchAIConnection(id: "c", name: "Cloud", provider: "claude", models: ["exact"], hasAPIKey: true),
                        OrchAIConnection(id: "c", name: "Cloud", provider: "openai", endpoint: "https://fixture.invalid", models: ["exact"], hasAPIKey: true)] {
            draft.connections = [changed]
            XCTAssertTrue(draft.validationErrors(original: original).contains("Enter an API key for each new or changed cloud connection."))
        }
    }

    func testValidationRejectsDanglingModelsAndEmptyCandidates() {
        let ref = AIModelReference(connectionID: "c", model: "model-1")
        var draft = OrchAIAgents(connections: [.init(id: "c", name: "Local", provider: "ollama", endpoint: "http://localhost:11434", models: ["model-1", "model-2"])], headModel: ref,
                                 agents: [.init(id: "a", name: "Reviewer", role: "Review code", modelOverride: ref)])
        XCTAssertTrue(draft.validationErrors(original: .init()).isEmpty)
        draft.connections[0].models.removeFirst()
        XCTAssertEqual(draft.validationErrors(original: .init()).count, 2)
        draft.headModel = nil
        draft.agents[0].modelOverride = nil
        XCTAssertTrue(draft.validationErrors(original: .init()).isEmpty)
        draft.connections = []
        XCTAssertTrue(draft.validationErrors(original: .init()).contains("Add at least one model for the head to assign to agents."))
    }

    func testValidationRejectsDuplicateModelsAndInvalidEndpoints() {
        for endpoint in ["", "ftp://localhost", "http://key:secret@localhost"] {
            let team = OrchAIAgents(connections: [.init(name: "Local", provider: "ollama", endpoint: endpoint, models: ["exact", "exact"])])
            XCTAssertEqual(team.validationErrors(original: .init()).count, 2)
        }
    }

    func testTeamAPIUsesAuthenticatedGetPutAndLeavesStoredCredentialsOmitted() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel(); TeamURLProtocol.handler = nil }
        TeamURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/orchs/orch/ai-agents")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            if request.httpMethod == "PUT" {
                let object = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                let connection = (object["connections"] as! [[String: Any]])[0]
                XCTAssertNil(connection["api_key"])
                XCTAssertNil(connection["has_api_key"])
                XCTAssertEqual(connection["models"] as? [String], ["exact"])
            } else { XCTAssertEqual(request.httpMethod, "GET") }
            return Data(#"{"connections":[{"id":"c","name":"Cloud","provider":"openai","models":["exact"],"has_api_key":true}],"head_model":null,"agents":[]}"#.utf8)
        }
        let api = APIClient(baseURL: URL(string: "https://fixture.invalid")!, session: session, apiKeyProvider: { "fixture-token" })
        let loaded = try await api.getOrchAIAgents(id: "orch")
        let saved = try await api.saveOrchAIAgents(id: "orch", configuration: loaded)
        XCTAssertTrue(saved.connections[0].hasAPIKey)
        XCTAssertNil(saved.connections[0].apiKey)
    }

    func testOnlyTeamChatGetsTheLongerTimeout() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel(); TeamURLProtocol.handler = nil }
        TeamURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            if body["agent_id"] != nil { XCTAssertEqual(request.timeoutInterval, 130) }
            else { XCTAssertNotEqual(request.timeoutInterval, 130) }
            return Data(#"{"type":"ask","message":"hello"}"#.utf8)
        }
        let api = APIClient(baseURL: URL(string: "https://fixture.invalid")!, session: session, apiKeyProvider: { "" })
        _ = try await api.chat(.init(history: [], message: "legacy"))
        _ = try await api.chat(.init(history: [], message: "team", orchestrationID: "orch", agentID: "agent"))
    }

    @MainActor
    func testPendingPlanKeepsItsSelectionAndSwitchingStartsFreshHistory() async {
        let client = StubTeamChatClient()
        client.response = ChatResponse(type: "plan", message: "Review first", plan: .init(intent: "inspect", actions: []), modelSelection: Self.selection)
        let vm = ChatViewModel(api: client, instructionProvider: { nil })
        XCTAssertTrue(vm.selectAgent(Self.target))
        await vm.send("Review", contextPreamble: "orch context")
        XCTAssertEqual(client.requests.first?.orchestrationID, "orch")
        XCTAssertEqual(client.requests.first?.agentID, "agent")
        XCTAssertEqual(client.requests.first?.message, "orch context\n\nReview")
        XCTAssertEqual(vm.pendingModelSelection, Self.selection)
        XCTAssertFalse(vm.selectAgent(nil))
        await vm.send("Do not overwrite a pending plan")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.executions.isEmpty, "Receiving a plan must never execute it")
        await vm.runPendingPlan()
        XCTAssertEqual(client.executions, [Self.selection])
        XCTAssertNil(vm.pendingPlan)
        XCTAssertEqual(vm.turns.last?.modelSelection, Self.selection)
        XCTAssertTrue(vm.selectAgent(nil))
        XCTAssertTrue(vm.turns.isEmpty)
        XCTAssertNil(vm.modelSelection)
        client.response = .init(type: "ask", message: "Default response", plan: nil)
        await vm.send("Default")
        XCTAssertNil(client.requests.last?.agentID)
        XCTAssertEqual(client.requests.last?.history.count, 1)
    }

    @MainActor
    func testInflightRequestCannotChangeTargetAndCancelClearsCapturedSelection() async {
        let client = StubTeamChatClient()
        client.response = ChatResponse(type: "plan", message: "Review", plan: .init(intent: "inspect", actions: []), modelSelection: Self.selection)
        let vm = ChatViewModel(api: client, instructionProvider: { nil })
        vm.selectAgent(Self.target)
        client.onChat = {
            XCTAssertTrue(vm.isThinking)
            XCTAssertFalse(vm.selectAgent(nil))
            XCTAssertEqual(vm.selectedAgent, Self.target)
        }
        await vm.send("Review")
        vm.cancelPendingPlan()
        XCTAssertNil(vm.pendingModelSelection)
        XCTAssertNil(vm.pendingPlan)
        XCTAssertTrue(vm.selectAgent(nil))
        XCTAssertTrue(client.executions.isEmpty)
    }

    @MainActor
    func testAgentPlanWithoutSelectionCannotRunAsDefaultHydra() async {
        let client = StubTeamChatClient()
        client.response = ChatResponse(type: "plan", message: "Legacy reply", plan: .init(intent: "inspect", actions: []))
        let vm = ChatViewModel(api: client, instructionProvider: { nil })
        vm.selectAgent(Self.target)
        await vm.send("Review")
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.pendingPlan)
        await vm.runPendingPlan()
        XCTAssertTrue(client.executions.isEmpty)
    }

    private static let selection = AgentModelSelection(orchestrationID: "orch", agentID: "agent", connectionID: "connection", provider: "openai", model: "exact-model-version", source: "head", reason: "Matches the role", teamRevision: "revision-1")
    private static let target = AgentChatTarget(orchestrationID: "orch", orchestrationName: "Fixture", agent: .init(id: "agent", name: "Reviewer", role: "Review code"), modelLabel: nil)

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private final class StubTeamChatClient: ChatClient {
    var requests: [ChatRequest] = []
    var executions: [AgentModelSelection?] = []
    var response = ChatResponse(type: "ask", message: "", plan: nil)
    var onChat: (() -> Void)?

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        onChat?()
        return response
    }

    func executePlan(_ plan: AgentPlan, modelSelection: AgentModelSelection?) async throws -> AgentExecuteResponse {
        executions.append(modelSelection)
        return AgentExecuteResponse(results: [], summary: nil)
    }
}

private final class TeamURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(contentsOf: buffer.prefix(read))
    }
    return data
}
