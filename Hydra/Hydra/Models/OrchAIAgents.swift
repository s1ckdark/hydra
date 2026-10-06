import Foundation

struct AIModelReference: Codable, Hashable {
    var connectionID: String
    var model: String

    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case model
    }
}

/// Credentials are accepted only as an in-memory edit. GET's has_api_key is
/// display metadata and is deliberately never serialized into a save request.
struct OrchAIConnection: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var provider: String = "claude"
    var endpoint: String = ""
    var models: [String] = [""]
    var hasAPIKey: Bool = false
    var apiKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, provider, endpoint, models
        case hasAPIKey = "has_api_key"
        case apiKey = "api_key"
    }

    init(id: String = UUID().uuidString, name: String = "", provider: String = "claude",
         endpoint: String = "", models: [String] = [""], hasAPIKey: Bool = false, apiKey: String? = nil) {
        self.id = id; self.name = name; self.provider = provider
        self.endpoint = endpoint; self.models = models
        self.hasAPIKey = hasAPIKey; self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        hasAPIKey = try c.decodeIfPresent(Bool.self, forKey: .hasAPIKey) ?? false
        // Masked server responses must never turn into a submitted credential.
        apiKey = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(provider, forKey: .provider)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(models, forKey: .models)
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try c.encode(apiKey, forKey: .apiKey)
        }
    }

    func canKeepStoredKey(from original: OrchAIAgents) -> Bool {
        original.connections.contains {
            $0.id == id && $0.provider == provider && $0.endpoint == endpoint && $0.hasAPIKey
        }
    }
}

struct OrchAIAgent: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var role: String = ""
    var modelOverride: AIModelReference? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, role
        case modelOverride = "model_override"
    }
}

struct OrchAIAgents: Codable, Equatable {
    var connections: [OrchAIConnection] = []
    var headModel: AIModelReference? = nil
    var agents: [OrchAIAgent] = []

    enum CodingKeys: String, CodingKey {
        case connections, agents
        case headModel = "head_model"
    }

    var modelReferences: [AIModelReference] {
        connections.flatMap { c in c.models.filter { !$0.isEmpty }.map { AIModelReference(connectionID: c.id, model: $0) } }
    }

    func contains(_ reference: AIModelReference) -> Bool {
        connections.contains { $0.id == reference.connectionID && $0.models.contains(reference.model) }
    }

    func label(for reference: AIModelReference) -> String {
        let name = connections.first { $0.id == reference.connectionID }?.name ?? reference.connectionID
        return "\(name) · \(reference.model)"
    }

    /// Stable localization keys; the sheet resolves these using the active language.
    func validationErrors(original: OrchAIAgents) -> [String] {
        var errors: [String] = []
        if Set(connections.map(\.id)).count != connections.count || Set(agents.map(\.id)).count != agents.count {
            errors.append("Agent and connection IDs must be unique.")
        }
        for c in connections {
            if c.id.isEmpty || c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Give every connection a name.")
            }
            if !AIProviderConfig.allProviders.contains(c.provider) { errors.append("Choose a supported provider.") }
            if c.models.isEmpty || c.models.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                errors.append("Enter at least one exact model ID for each connection.")
            }
            if Set(c.models).count != c.models.count { errors.append("Model IDs must be unique within a connection.") }
            if c.models.contains(where: { $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                errors.append("Remove leading or trailing spaces from model IDs.")
            }
            if AIProviderConfig.isCloudProvider(c.provider),
               (c.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !c.canKeepStoredKey(from: original) {
                errors.append("Enter an API key for each new or changed cloud connection.")
            }
            if !c.endpoint.isEmpty || AIProviderConfig.localProviders.contains(c.provider) {
                let url = URL(string: c.endpoint)
                if !["http", "https"].contains(url?.scheme?.lowercased() ?? "") || url?.host == nil || url?.user != nil || url?.password != nil || url?.query != nil || url?.fragment != nil {
                    errors.append("Enter an HTTP or HTTPS endpoint without embedded credentials.")
                }
            }
        }
        if let headModel, !contains(headModel) { errors.append("Select an available head model or use global AI settings.") }
        for agent in agents {
            if agent.id.isEmpty || agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Give every agent a name and role instructions.")
            }
            if let ref = agent.modelOverride, !contains(ref) {
                errors.append("An agent refers to a removed connection or model. Choose another model or let the head decide.")
            }
            if agent.modelOverride == nil && modelReferences.isEmpty {
                errors.append("Add at least one model for the head to assign to agents.")
            }
        }
        var seen = Set<String>()
        return errors.filter { seen.insert($0).inserted }
    }
}

struct AgentModelSelection: Codable, Equatable {
    let orchestrationID: String
    let agentID: String
    let connectionID: String
    let provider: String
    let model: String
    let source: String
    let reason: String?
    var teamRevision: String? = nil

    enum CodingKeys: String, CodingKey {
        case orchestrationID = "orchestration_id"
        case agentID = "agent_id"
        case connectionID = "connection_id"
        case provider, model, source, reason
        case teamRevision = "team_revision"
    }
}

struct AgentChatTarget: Equatable {
    let orchestrationID: String
    let orchestrationName: String
    let agent: OrchAIAgent
    let modelLabel: String?
}
