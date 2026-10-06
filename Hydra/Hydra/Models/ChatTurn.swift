import Foundation

/// One row in the chat history. `role` mirrors the Go side exactly:
///   - user
///   - assistant_ask
///   - assistant_plan
///   - system_result
struct ChatTurn: Codable, Identifiable {
    let id = UUID()
    let role: String
    var content: String
    var plan: AgentPlan?
    var results: [ActionResult]?
    var modelSelection: AgentModelSelection? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, plan, results
        case modelSelection = "model_selection"
    }
}

struct ChatRequest: Codable {
    var history: [ChatTurn]
    var message: String
    /// Optional per-request system instruction (the Settings field). Sent so
    /// it applies immediately without a separate Save & Push.
    var instruction: String? = nil
    var orchestrationID: String? = nil
    var agentID: String? = nil

    enum CodingKeys: String, CodingKey {
        case history, message, instruction
        case orchestrationID = "orchestration_id"
        case agentID = "agent_id"
    }
}

struct AgentExecuteRequest: Codable {
    let plan: AgentPlan
    var modelSelection: AgentModelSelection? = nil
    var runID: String? = nil

    enum CodingKeys: String, CodingKey {
        case plan
        case modelSelection = "model_selection"
        case runID = "run_id"
    }
}
