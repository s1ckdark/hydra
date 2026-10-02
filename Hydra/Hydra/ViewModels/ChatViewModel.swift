import Foundation

typealias AgentProgressHandler = @MainActor @Sendable (AgentRunSnapshot) async -> Void

protocol ChatClient {
    func chat(_ request: ChatRequest) async throws -> ChatResponse
    func executePlan(_ plan: AgentPlan, modelSelection: AgentModelSelection?) async throws -> AgentExecuteResponse
    func chatStreaming(_ request: ChatRequest, onProgress: @escaping AgentProgressHandler) async throws -> ChatResponse
    func executePlanStreaming(_ plan: AgentPlan, modelSelection: AgentModelSelection?, runID: String?,
                              onProgress: @escaping AgentProgressHandler) async throws -> AgentExecuteResponse
}

extension ChatClient {
    func chatStreaming(_ request: ChatRequest, onProgress: @escaping AgentProgressHandler) async throws -> ChatResponse {
        try await chat(request)
    }

    func executePlanStreaming(_ plan: AgentPlan, modelSelection: AgentModelSelection?, runID: String?,
                              onProgress: @escaping AgentProgressHandler) async throws -> AgentExecuteResponse {
        try await executePlan(plan, modelSelection: modelSelection)
    }
}

extension APIClient: ChatClient {}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isThinking = false
    @Published var pendingPlan: AgentPlan?
    @Published var pendingPlanMessage: String?
    @Published var lastResults: [ActionResult]?
    @Published var error: String?
    @Published private(set) var selectedAgent: AgentChatTarget?
    @Published private(set) var modelSelection: AgentModelSelection?
    @Published private(set) var pendingModelSelection: AgentModelSelection?
    @Published private(set) var pendingRunID: String?
    @Published private(set) var agentRun: AgentRunSnapshot?
    @Published private(set) var runOrchestrationID: String?
    @Published private(set) var progressUnavailable = false
    @Published private(set) var progressDisconnected = false
    private var progressGeneration = UUID()

    /// History sent to the server is capped at the last 20 turns. The
    /// UI keeps the full list so the user can scroll back.
    private let serverHistoryCap = 20

    private let api: any ChatClient
    private let instructionProvider: () -> String?

    init(api: any ChatClient = APIClient.shared,
         instructionProvider: @escaping () -> String? = { UserDefaults.standard.string(forKey: "aiInstruction") }) {
        self.api = api
        self.instructionProvider = instructionProvider
    }

    var canSwitchAgent: Bool { !isThinking && pendingPlan == nil }
    var canSend: Bool { !isThinking && pendingPlan == nil }

    /// Switching is explicit and starts a fresh history. Pending plans and
    /// requests keep their original target until run/cancel has completed.
    @discardableResult
    func selectAgent(_ target: AgentChatTarget?) -> Bool {
        guard canSwitchAgent else { return false }
        guard selectedAgent != target else { return true }
        selectedAgent = target
        turns = []
        modelSelection = nil
        pendingModelSelection = nil
        pendingRunID = nil
        agentRun = nil
        runOrchestrationID = nil
        progressUnavailable = false
        progressDisconnected = false
        progressGeneration = UUID()
        lastResults = nil
        error = nil
        return true
    }

    func send(_ message: String, contextPreamble: String? = nil) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend else { return }
        turns.append(ChatTurn(role: "user", content: trimmed, plan: nil, results: nil))
        isThinking = true
        error = nil
        agentRun = nil
        runOrchestrationID = selectedAgent?.orchestrationID
        progressUnavailable = false
        progressDisconnected = false
        let generation = UUID()
        progressGeneration = generation
        defer { isThinking = false }
        let history = Array(turns.suffix(serverHistoryCap))
        // Preamble is composed by the caller from active tab + selection;
        // we attach it only to the outbound message, never to the on-screen
        // turn text — the user shouldn't see their own boilerplate echoed.
        let outbound: String
        if let preamble = contextPreamble, !preamble.isEmpty {
            outbound = "\(preamble)\n\n\(trimmed)"
        } else {
            outbound = trimmed
        }
        let instr = instructionProvider()
        let req = ChatRequest(history: history, message: outbound,
                              instruction: (instr?.isEmpty == false) ? instr : nil,
                              orchestrationID: selectedAgent?.orchestrationID,
                              agentID: selectedAgent?.agent.id)
        do {
            let resp = try await api.chatStreaming(req) { [weak self] snapshot in
                guard let self, self.progressGeneration == generation, self.isThinking else { return }
                // A chat stream belongs to one run. A later response from a
                // stale request must never replace the new conversation.
                guard self.agentRun == nil || self.agentRun?.runID == snapshot.runID else { return }
                self.agentRun = snapshot
            }
            progressUnavailable = agentRun == nil
            if let target = selectedAgent {
                guard let selection = resp.modelSelection,
                      selection.orchestrationID == target.orchestrationID,
                      selection.agentID == target.agent.id,
                      !selection.model.isEmpty, !selection.connectionID.isEmpty else {
                    self.error = AppLocalization.string("The server did not return the selected agent's model. Send the request again after updating the server.")
                    return
                }
            }
            let role = resp.type == "plan" ? "assistant_plan" : "assistant_ask"
            modelSelection = resp.modelSelection
            turns.append(ChatTurn(role: role, content: resp.message, plan: resp.plan, results: nil,
                                  modelSelection: resp.modelSelection))
            if resp.type == "plan" {
                pendingPlan = resp.plan
                pendingPlanMessage = resp.message
                pendingModelSelection = resp.modelSelection
                pendingRunID = resp.runID ?? agentRun?.runID
            }
        } catch {
            self.error = error.localizedDescription
            recordProgressFailure(error)
        }
    }

    func runPendingPlan() async {
        guard let plan = pendingPlan, !isThinking else { return }
        // Captured when the plan was generated, never derived from the UI's
        // current target or a newer configuration at execution time.
        let selection = pendingModelSelection
        let runID = pendingRunID
        let generation = UUID()
        progressGeneration = generation
        isThinking = true
        error = nil
        progressDisconnected = false
        var receivedProgress = false
        defer { isThinking = false }
        do {
            let resp = try await api.executePlanStreaming(plan, modelSelection: selection, runID: runID) { [weak self] snapshot in
                guard let self, self.progressGeneration == generation, self.isThinking,
                      runID == nil || snapshot.runID == runID else { return }
                receivedProgress = true
                if let previous = self.agentRun, previous.runID == snapshot.runID {
                    self.agentRun = previous.mergingExecution(snapshot)
                } else {
                    self.agentRun = snapshot
                }
                self.progressUnavailable = false
            }
            if !receivedProgress {
                progressUnavailable = true
                // Planning evidence is retained, but its waiting/running
                // badges no longer claim to describe an unobserved execution.
                agentRun?.markDisconnected()
            }
            lastResults = resp.results
            turns.append(ChatTurn(
                role: "system_result",
                content: summary(of: resp.results),
                plan: nil,
                results: resp.results,
                modelSelection: selection
            ))
            pendingPlan = nil
            pendingPlanMessage = nil
            pendingModelSelection = nil
            pendingRunID = nil
        } catch {
            self.error = error.localizedDescription + "\n" + AppLocalization.string("Execution may have changed the system. Check its state before requesting another plan.")
            recordProgressFailure(error)
            // The server may already have performed actions. Remove the Run
            // affordance so an uncertain request cannot simply be replayed.
            pendingPlan = nil
            pendingPlanMessage = nil
            pendingModelSelection = nil
            pendingRunID = nil
        }
    }

    func cancelPendingPlan() {
        guard !isThinking else { return }
        if pendingPlan != nil { agentRun?.cancelApproval() }
        pendingPlan = nil
        pendingPlanMessage = nil
        pendingModelSelection = nil
        pendingRunID = nil
        progressGeneration = UUID()
    }

    private func recordProgressFailure(_ error: Error) {
        progressUnavailable = agentRun == nil
        let explicitServerError: Bool
        switch error {
        case AgentStreamError.server, APIError.server: explicitServerError = true
        default: explicitServerError = false
        }
        if explicitServerError {
            // A delivered server failure is not a lost connection. Preserve
            // confirmed terminal evidence; earlier nonterminal badges cannot
            // keep claiming that work is still running after an error.
            progressDisconnected = false
            if let phase = agentRun?.phase, !["completed", "failed", "cancelled"].contains(phase) {
                agentRun?.markDisconnected()
            }
        } else {
            progressDisconnected = true
            agentRun?.markDisconnected()
        }
    }

    private func summary(of results: [ActionResult]) -> String {
        let ok = results.filter { $0.status == "ok" }.count
        let fail = results.count - ok
        if fail == 0 { return "✓ all \(ok) action(s) completed" }
        return "ran \(results.count) action(s) — \(ok) ok, \(fail) failed"
    }
}
