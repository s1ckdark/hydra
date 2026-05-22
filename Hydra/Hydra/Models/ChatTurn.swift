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

    enum CodingKeys: String, CodingKey { case role, content, plan, results }
}

struct ChatRequest: Codable {
    var history: [ChatTurn]
    var message: String
}

struct AgentExecuteRequest: Codable {
    let plan: AgentPlan
}
