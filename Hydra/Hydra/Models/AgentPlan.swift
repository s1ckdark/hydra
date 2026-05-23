import Foundation

/// One action in an LLM-proposed plan. `args` mirrors the Go side as
/// raw JSON so we can show it verbatim without enumerating every shape.
struct AgentAction: Codable, Identifiable {
    let id = UUID()
    let type: String
    let args: AnyCodable

    enum CodingKeys: String, CodingKey { case type, args }
}

/// Plan = intent + ordered actions.
struct AgentPlan: Codable {
    let intent: String
    let actions: [AgentAction]
}

/// Server reply to POST /api/agent/chat. Either `ask` (clarifying
/// question, no plan) or `plan` (intent + actions). `message` always
/// present.
struct ChatResponse: Codable {
    let type: String
    let message: String
    let plan: AgentPlan?
}

/// Per-action result returned by /api/agent/execute.
struct ActionResult: Codable, Identifiable {
    let id = UUID()
    let type: String
    let status: String   // "ok" | "error"
    let output: AnyCodable?
    let error: String?

    enum CodingKeys: String, CodingKey { case type, status, output, error }
}

struct AgentExecuteResponse: Codable {
    let results: [ActionResult]
}

extension AgentPlan {
    /// One-line action label for the menubar's compact PlanCard:
    /// the first action's `type`, with `(+N more)` appended when the
    /// plan has more than one action.
    var compactActionLabel: String {
        guard let first = actions.first else { return "" }
        if actions.count == 1 { return first.type }
        return "\(first.type) (+\(actions.count - 1) more)"
    }
}

/// AnyCodable wraps the JSON-typed values we round-trip through the
/// agent endpoints without modelling every action's shape.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                       { self.value = NSNull() }
        else if let v = try? c.decode(Bool.self)    { self.value = v }
        else if let v = try? c.decode(Int.self)     { self.value = v }
        else if let v = try? c.decode(Double.self)  { self.value = v }
        else if let v = try? c.decode(String.self)  { self.value = v }
        else if let v = try? c.decode([AnyCodable].self) { self.value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues(\.value)
        } else { self.value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:                 try c.encodeNil()
        case let v as Bool:              try c.encode(v)
        case let v as Int:               try c.encode(v)
        case let v as Double:            try c.encode(v)
        case let v as String:            try c.encode(v)
        case let v as [Any]:             try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]:     try c.encode(v.mapValues(AnyCodable.init))
        default:                         try c.encodeNil()
        }
    }
}
