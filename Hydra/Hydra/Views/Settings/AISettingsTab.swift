import SwiftUI

#if os(macOS)
struct AISettingsTab: View {
    @AppStorage("serverURL") private var serverURL = "http://localhost:8080"
    @AppStorage("aiDefaultProvider") private var provider: String = "claude"
    @AppStorage("aiDefaultEndpoint") private var endpoint: String = ""
    @AppStorage("aiDefaultModel") private var model: String = ""

    @State private var authMethod: AuthMethod = .apiKey
    @State private var apiKey: String = ""
    @State private var connectionVerified = false
    @State private var testStatus: TestStatus?
    @State private var saveStatus: SaveStatus?
    @State private var showAdvanced = false

    private let store = CredentialStore.shared

    enum AuthMethod: String, CaseIterable {
        case apiKey = "API Key"
        case localAPI = "Local API"
    }

    enum TestStatus {
        case testing
        case success(String)
        case error(String)
    }

    enum SaveStatus {
        case saving
        case savedLocally
        case pushedToServer
        case error(String)
    }

    private var cloudProviders: [String] { ["claude", "openai", "zai"] }
    private var localProviders: [String] { ["ollama", "lmstudio", "openai_compatible"] }
    private var currentProviders: [String] {
        authMethod == .apiKey ? cloudProviders : localProviders
    }

    var body: some View {
        Form {
            Section {
                Picker("Auth Method", selection: $authMethod) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: authMethod) {
                    // Reset provider to first available when switching modes
                    if !currentProviders.contains(provider) {
                        provider = currentProviders.first ?? ""
                    }
                    credentialsChanged()
                }

                Picker("Provider", selection: $provider) {
                    ForEach(currentProviders, id: \.self) { p in
                        Text(p).tag(p)
                    }
                }
                .onChange(of: provider) { credentialsChanged() }

                if authMethod == .apiKey {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { credentialsChanged() }
                } else {
                    TextField("Endpoint", text: $endpoint, prompt: Text("http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: endpoint) { credentialsChanged() }
                }

                TextField("Model (optional)", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { credentialsChanged() }
            } header: {
                Text("① AI Provider (Default)")
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Image(systemName: "bolt.horizontal.circle")
                        Text("Test Connection")
                    }
                }
                .disabled(testStatus.isTesting || !hasCredentials)

                if let status = testStatus {
                    switch status {
                    case .testing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Testing…").font(.caption)
                        }
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Text("② Verify")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = store.get(.aiDefaultAPIKey)
            if !endpoint.isEmpty { authMethod = .localAPI }
        }
    }

    private func credentialsChanged() {
        connectionVerified = false
        testStatus = nil
        saveStatus = nil
    }

    private var hasCredentials: Bool {
        if authMethod == .apiKey { return !apiKey.isEmpty }
        return !endpoint.isEmpty
    }

    private func testConnection() async {
        withAnimation { testStatus = .testing }

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
            urlString = endpoint.trimmingCharacters(in: .whitespaces) + "/api/tags"
        case "lmstudio", "openai_compatible":
            urlString = endpoint.trimmingCharacters(in: .whitespaces) + "/v1/models"
        default:
            withAnimation { testStatus = .error("Unknown provider: \(provider)") }
            return
        }

        guard let url = URL(string: urlString) else {
            withAnimation { testStatus = .error("Invalid endpoint URL") }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                withAnimation { testStatus = .error("No response") }
                return
            }
            if (200...299).contains(http.statusCode) {
                withAnimation {
                    connectionVerified = true
                    testStatus = .success("Connected to \(provider)")
                }
            } else {
                withAnimation { testStatus = .error("\(provider) returned HTTP \(http.statusCode)") }
            }
        } catch {
            withAnimation { testStatus = .error("Connection failed: \(error.localizedDescription)") }
        }
    }
}

private extension Optional where Wrapped == AISettingsTab.TestStatus {
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}
#endif
