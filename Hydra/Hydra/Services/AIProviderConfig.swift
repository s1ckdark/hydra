import Foundation

/// Cross-platform domain helpers for the AI provider configuration UI.
/// SwiftUI views (iOS and macOS) call into this so provider labels,
/// cloud/local classification, and test-connection request shapes have
/// a single source of truth and don't drift between platforms.
enum AIProviderConfig {
    static let allProviders: [String] = [
        "claude", "openai", "zai", "ollama", "lmstudio", "openai_compatible",
    ]
    static let cloudProviders: Set<String> = ["claude", "openai", "zai"]
    static let localProviders: Set<String> = ["ollama", "lmstudio", "openai_compatible"]

    /// True iff `id` is a cloud provider that authenticates with an API key.
    static func isCloudProvider(_ id: String) -> Bool {
        cloudProviders.contains(id)
    }

    /// Display label combining provider id with its `(cloud)` / `(local)` hint.
    static func label(for id: String) -> String {
        switch id {
        case "claude":             return "Claude (cloud)"
        case "openai":             return "OpenAI (cloud)"
        case "zai":                return "Z.AI (cloud)"
        case "ollama":             return "Ollama (local)"
        case "lmstudio":           return "LM Studio (local)"
        case "openai_compatible":  return "OpenAI-compatible (local)"
        default:                   return id
        }
    }

    /// Builds the URLRequest used to ping a provider's `/models` (or `/api/tags`)
    /// endpoint. Returns nil for an unknown provider, an empty/whitespace
    /// endpoint for a local provider, or a URL that fails to parse.
    /// Cloud providers ignore `endpoint`; local providers ignore `apiKey`.
    static func testConnectionRequest(provider: String, apiKey: String, endpoint: String) -> URLRequest? {
        let urlString: String
        var headers: [String: String] = [:]

        switch provider {
        case "claude":
            urlString = "https://api.anthropic.com/v1/models"
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case "openai":
            urlString = "https://api.openai.com/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case "zai":
            urlString = "https://api.z.ai/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case "ollama":
            let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            urlString = trimmed + "/api/tags"
        case "lmstudio", "openai_compatible":
            let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            urlString = trimmed + "/v1/models"
        default:
            return nil
        }

        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }
}
