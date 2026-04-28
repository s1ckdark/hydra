import XCTest
@testable import Hydra

final class AIProviderConfigTests: XCTestCase {
    // MARK: - label(for:)

    func testProviderLabel_KnownIDs() {
        XCTAssertEqual(AIProviderConfig.label(for: "claude"), "Claude (cloud)")
        XCTAssertEqual(AIProviderConfig.label(for: "openai"), "OpenAI (cloud)")
        XCTAssertEqual(AIProviderConfig.label(for: "zai"), "Z.AI (cloud)")
        XCTAssertEqual(AIProviderConfig.label(for: "ollama"), "Ollama (local)")
        XCTAssertEqual(AIProviderConfig.label(for: "lmstudio"), "LM Studio (local)")
        XCTAssertEqual(AIProviderConfig.label(for: "openai_compatible"), "OpenAI-compatible (local)")
    }

    func testProviderLabel_UnknownIDFallback() {
        XCTAssertEqual(AIProviderConfig.label(for: "wat"), "wat")
        XCTAssertEqual(AIProviderConfig.label(for: ""), "")
    }

    // MARK: - isCloudProvider(_:)

    func testIsCloudProvider_TrueForCloud() {
        XCTAssertTrue(AIProviderConfig.isCloudProvider("claude"))
        XCTAssertTrue(AIProviderConfig.isCloudProvider("openai"))
        XCTAssertTrue(AIProviderConfig.isCloudProvider("zai"))
    }

    func testIsCloudProvider_FalseForLocal() {
        XCTAssertFalse(AIProviderConfig.isCloudProvider("ollama"))
        XCTAssertFalse(AIProviderConfig.isCloudProvider("lmstudio"))
        XCTAssertFalse(AIProviderConfig.isCloudProvider("openai_compatible"))
    }

    func testIsCloudProvider_FalseForUnknown() {
        XCTAssertFalse(AIProviderConfig.isCloudProvider("wat"))
    }

    // MARK: - testConnectionRequest

    func testTestConnectionRequest_ClaudeHeaders() {
        let req = AIProviderConfig.testConnectionRequest(provider: "claude", apiKey: "sk-ant-x", endpoint: "")
        XCTAssertEqual(req?.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-x")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testTestConnectionRequest_OpenAIBearerAuth() {
        let req = AIProviderConfig.testConnectionRequest(provider: "openai", apiKey: "sk-y", endpoint: "")
        XCTAssertEqual(req?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-y")
    }

    func testTestConnectionRequest_ZAIBearerAuth() {
        let req = AIProviderConfig.testConnectionRequest(provider: "zai", apiKey: "sk-z", endpoint: "")
        XCTAssertEqual(req?.url?.absoluteString, "https://api.z.ai/v1/models")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-z")
    }

    func testTestConnectionRequest_OllamaURL() {
        let req = AIProviderConfig.testConnectionRequest(provider: "ollama", apiKey: "", endpoint: "  http://192.168.1.5:11434  ")
        XCTAssertEqual(req?.url?.absoluteString, "http://192.168.1.5:11434/api/tags")
    }

    func testTestConnectionRequest_LMStudioURL() {
        let req = AIProviderConfig.testConnectionRequest(provider: "lmstudio", apiKey: "", endpoint: "http://127.0.0.1:1234")
        XCTAssertEqual(req?.url?.absoluteString, "http://127.0.0.1:1234/v1/models")
    }

    func testTestConnectionRequest_OpenAICompatibleURL() {
        let req = AIProviderConfig.testConnectionRequest(provider: "openai_compatible", apiKey: "", endpoint: "http://example.test:8080")
        XCTAssertEqual(req?.url?.absoluteString, "http://example.test:8080/v1/models")
    }

    func testTestConnectionRequest_NilForUnknownProvider() {
        XCTAssertNil(AIProviderConfig.testConnectionRequest(provider: "wat", apiKey: "k", endpoint: "e"))
    }

    func testTestConnectionRequest_NilForInvalidURL() {
        // Endpoint that becomes only whitespace after trim — local provider should reject.
        let req = AIProviderConfig.testConnectionRequest(provider: "ollama", apiKey: "", endpoint: " ")
        XCTAssertNil(req)
    }
}
