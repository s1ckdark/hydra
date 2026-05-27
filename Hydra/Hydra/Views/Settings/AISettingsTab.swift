import SwiftUI

#if os(macOS)
struct AISettingsTab: View {
    // Single provider dropdown — no separate Auth Method toggle.
    // Provider value drives whether API Key field or Endpoint field is shown.
    @AppStorage("serverURL") private var serverURL = "http://localhost:8080"
    @AppStorage("aiDefaultProvider") private var provider: String = "claude"
    @AppStorage("aiDefaultEndpoint") private var endpoint: String = ""
    @AppStorage("aiDefaultModel") private var model: String = ""

    @State private var apiKey: String = ""
    @State private var connectionVerified = false
    @State private var testStatus: TestStatus?
    @State private var saveStatus: SaveStatus?
    @State private var showAdvanced = false

    private let store = CredentialStore.shared

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

    /// Cloud providers require an API key; local providers require an endpoint URL.
    static let cloudProviders: Set<String> = ["claude", "openai", "zai"]
    static let localProviders: Set<String> = ["ollama", "lmstudio", "openai_compatible"]

    /// Z.AI GLM Coding Plan base URL (OpenAI-compatible). The older "/v1"
    /// base does not serve the Coding Plan.
    static let zaiCodingEndpoint = "https://api.z.ai/api/coding/paas/v4"

    /// Known model ids offered as a dropdown per cloud provider. The text
    /// field stays editable so custom / local model names still work.
    static func knownModels(for provider: String) -> [String] {
        switch provider {
        case "claude": return ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case "openai": return ["gpt-4o", "gpt-4o-mini", "o3-mini"]
        case "zai":    return ["glm-4.6", "glm-4.5", "glm-4.5-air"]
        default:       return []
        }
    }

    private var isCloudProvider: Bool { Self.cloudProviders.contains(provider) }
    private var needsAPIKey: Bool { Self.cloudProviders.contains(provider) }
    /// z.ai needs an API key AND a base URL (the Coding Plan endpoint), so it
    /// shows both fields; local providers need only an endpoint.
    private var needsEndpoint: Bool { Self.localProviders.contains(provider) || provider == "zai" }

    private func isCloudProviderID(_ id: String) -> Bool {
        return Self.cloudProviders.contains(id)
    }

    /// Display label combining provider id with its group hint.
    private func label(for id: String) -> String {
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

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    Text(label(for: "claude")).tag("claude")
                    Text(label(for: "openai")).tag("openai")
                    Text(label(for: "zai")).tag("zai")
                    Text(label(for: "ollama")).tag("ollama")
                    Text(label(for: "lmstudio")).tag("lmstudio")
                    Text(label(for: "openai_compatible")).tag("openai_compatible")
                }
                .onChange(of: provider) { providerChanged() }

                if needsAPIKey {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { credentialsChanged() }
                }
                if needsEndpoint {
                    TextField("Endpoint", text: $endpoint, prompt: Text(endpointPlaceholder))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: endpoint) { credentialsChanged() }
                }

                // Model: free-text (local models vary) plus a dropdown of
                // known ids for the selected cloud provider.
                HStack(spacing: 6) {
                    TextField("Model (optional)", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model) { credentialsChanged() }
                    let known = Self.knownModels(for: provider)
                    if !known.isEmpty {
                        Menu {
                            ForEach(known, id: \.self) { m in
                                Button(m) { model = m; credentialsChanged() }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Pick a known \(label(for: provider)) model")
                    }
                }
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

            Section {
                DisclosureGroup("Advanced: per-role overrides", isExpanded: $showAdvanced) {
                    RoleOverrideView(title: "Head Selection", role: "head")
                    RoleOverrideView(title: "Task Scheduling", role: "schedule")
                    RoleOverrideView(title: "Capacity Estimation", role: "capacity")
                    RoleOverrideView(title: "Chat agent — natural-language input", role: "chat")
                }
            } header: {
                Text("③ Advanced (optional)")
            }

            Section {
                HStack {
                    Button("Save Locally") { saveLocally() }
                        // Also disable while pushToServer is in flight — clicking
                        // mid-PUT would mutate saveStatus and re-enable Save & Push,
                        // allowing duplicate concurrent requests.
                        .disabled(!connectionVerified || saveStatus.isSaving)

                    Spacer()

                    Button("Save & Push to Server") {
                        Task { await pushToServer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connectionVerified || saveStatus.isSaving)
                }

                if !connectionVerified {
                    Text("Test the connection first before saving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let status = saveStatus {
                    switch status {
                    case .saving:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Pushing to server…").font(.caption)
                        }
                    case .savedLocally:
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .pushedToServer:
                        Label("Saved locally & pushed to server", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Text("④ Save")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = store.get(.aiDefaultAPIKey)
            if provider == "zai" && endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
                endpoint = Self.zaiCodingEndpoint
            }
        }
    }

    /// Placeholder hint for the endpoint field, per provider.
    private var endpointPlaceholder: String {
        provider == "zai" ? Self.zaiCodingEndpoint : "http://localhost:11434"
    }

    private func credentialsChanged() {
        connectionVerified = false
        testStatus = nil
        saveStatus = nil
    }

    /// On provider change: reset verification and, for z.ai, prefill the
    /// Coding Plan base URL so it's visible and editable rather than relying
    /// on a hidden server default.
    private func providerChanged() {
        credentialsChanged()
        if provider == "zai" && endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            endpoint = Self.zaiCodingEndpoint
        }
    }

    private var hasCredentials: Bool {
        if isCloudProvider { return !apiKey.isEmpty }
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
            let base = endpoint.trimmingCharacters(in: .whitespaces)
            urlString = (base.isEmpty ? Self.zaiCodingEndpoint : base) + "/models"
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

    private func saveLocally() {
        // Only persist a key when the chosen provider needs one.
        store.set(.aiDefaultAPIKey, value: isCloudProvider ? apiKey : "")
        withAnimation { saveStatus = .savedLocally }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { saveStatus = nil }
        }
    }

    private func pushToServer() async {
        withAnimation { saveStatus = .saving }
        // Persist the API key to Keychain alongside the network push, but
        // do NOT call saveLocally() here — it would flip saveStatus to
        // .savedLocally before the PUT completes, re-enabling the Save &
        // Push button mid-request because its disabled-state checks
        // saveStatus.isSaving.
        store.set(.aiDefaultAPIKey, value: isCloudProvider ? apiKey : "")

        var defaultPayload: [String: String] = [
            "provider": provider,
            "model":    model,
        ]
        if needsAPIKey {
            defaultPayload["api_key"] = apiKey
        }
        if needsEndpoint {
            defaultPayload["endpoint"] = endpoint
        }

        let defaults = UserDefaults.standard
        var body: [String: Any] = ["default": defaultPayload]

        let roleKeys = [
            ("head_selection",      "head"),
            ("task_scheduling",     "schedule"),
            ("capacity_estimation", "capacity"),
            ("chat_input",          "chat"),
        ]
        for (jsonKey, roleSlug) in roleKeys {
            let raw = defaults.object(forKey: "aiRole_\(roleSlug)_useDefault")
            let useDefault = (raw as? Bool) ?? true   // unset → use default (true)
            if useDefault {
                continue
            }
            let roleProvider = defaults.string(forKey: "aiRole_\(roleSlug)_provider") ?? ""
            let roleEndpoint = defaults.string(forKey: "aiRole_\(roleSlug)_endpoint") ?? ""
            let roleModel    = defaults.string(forKey: "aiRole_\(roleSlug)_model")    ?? ""
            if roleProvider.isEmpty {
                continue
            }
            var override: [String: String] = ["provider": roleProvider, "model": roleModel]
            if isCloudProviderID(roleProvider) {
                // The endpoint slot in the Advanced UI doubles as the API key
                // input — this is acknowledged tech debt from the prior PR. Treat
                // its value as api_key for cloud providers.
                override["api_key"] = roleEndpoint
            } else {
                override["endpoint"] = roleEndpoint
            }
            body[jsonKey] = override
        }

        guard let baseURL = URL(string: serverURL) else {
            withAnimation { saveStatus = .error("Invalid server URL: \(serverURL)") }
            return
        }

        do {
            let url = baseURL.appendingPathComponent("api/config/ai")
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let serverKey = store.get(.serverAPIKey)
            if !serverKey.isEmpty {
                request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                withAnimation { saveStatus = .error("Server returned \(code)") }
                return
            }

            withAnimation { saveStatus = .pushedToServer }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { saveStatus = nil }
            }
        } catch {
            withAnimation { saveStatus = .error(error.localizedDescription) }
        }
    }
}

private extension Optional where Wrapped == AISettingsTab.TestStatus {
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

private extension Optional where Wrapped == AISettingsTab.SaveStatus {
    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}

private struct RoleOverrideView: View {
    let title: String
    let role: String

    @AppStorage private var useDefault: Bool
    @AppStorage private var provider: String
    @AppStorage private var endpoint: String
    @AppStorage private var model: String

    init(title: String, role: String) {
        self.title = title
        self.role = role
        self._useDefault = AppStorage(wrappedValue: true, "aiRole_\(role)_useDefault")
        self._provider   = AppStorage(wrappedValue: "",   "aiRole_\(role)_provider")
        self._endpoint   = AppStorage(wrappedValue: "",   "aiRole_\(role)_endpoint")
        self._model      = AppStorage(wrappedValue: "",   "aiRole_\(role)_model")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: Binding(
                get: { useDefault },
                set: { useDefault = $0 }
            ))
            .toggleStyle(.switch)
            .font(.headline)

            if !useDefault {
                HStack {
                    Text("Provider")
                    Spacer()
                    TextField("claude, openai, ollama…", text: $provider)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                HStack {
                    Text("Endpoint / Key")
                    Spacer()
                    SecureField("api key or endpoint URL", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                HStack {
                    Text("Model")
                    Spacer()
                    TextField("(optional)", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                Text("Overrides are stored locally. Push to server to apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uses the default provider above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
