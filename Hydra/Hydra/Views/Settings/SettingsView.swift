import SwiftUI

#if os(macOS)
struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "server.rack") }

            TailscaleSettingsTab()
                .tabItem { Label("Tailscale", systemImage: "network") }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Server Settings

private struct ServerSettingsTab: View {
    @AppStorage("serverURL") private var serverURL = "http://localhost:8080"
    @State private var apiKey: String = ""
    @State private var saved = false

    private let store = CredentialStore.shared

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key (optional)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("Only needed when connecting from outside the Tailscale network. On localhost or Tailscale, requests are authenticated automatically.\n\nTo generate a key: run `hydra config set api-key <your-key>` on the server, then enter the same key here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hydra Server Connection")
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }

                    Spacer()

                    Button("Save") {
                        store.set(.serverAPIKey, value: apiKey)
                        withAnimation { saved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { saved = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = store.get(.serverAPIKey)
        }
    }

    @State private var connectionStatus: String?

    private func testConnection() async {
        do {
            let url = URL(string: serverURL)!.appendingPathComponent("health")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                connectionStatus = "Failed: non-200 response"
                return
            }
            if let json = try? JSONDecoder().decode([String: String].self, from: data),
               let status = json["status"] {
                connectionStatus = "Connected — \(status)"
            }
        } catch {
            connectionStatus = "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tailscale Settings

private struct TailscaleSettingsTab: View {
    @AppStorage("tailscaleTailnet") private var tailnet = ""
    @AppStorage("serverURL") private var serverURL = "http://localhost:8080"
    @State private var apiKey = ""
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var authMethod: AuthMethod = .apiKey
    @State private var connectionVerified = false
    @State private var testStatus: TestStatus?
    @State private var saveStatus: SaveStatus?
    @State private var deviceCount: Int?

    private let store = CredentialStore.shared

    enum AuthMethod: String, CaseIterable {
        case apiKey = "API Key"
        case oauth = "OAuth"
    }

    enum TestStatus {
        case testing, success(String), error(String)
    }

    enum SaveStatus {
        case saving, savedLocally, pushedToServer, error(String)
    }

    /// Reset verification when credentials change
    private func credentialsChanged() {
        connectionVerified = false
        testStatus = nil
        saveStatus = nil
        deviceCount = nil
    }

    var body: some View {
        Form {
            // Step 1: Tailnet
            Section {
                TextField("Tailnet", text: $tailnet)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tailnet) { credentialsChanged() }
                Text("Your Tailscale tailnet name (e.g. \"myteam.org\" or use \"-\" for default)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("① Tailscale Network")
            }

            // Step 2: Credentials
            Section {
                Picker("Auth Method", selection: $authMethod) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: authMethod) { credentialsChanged() }

                if authMethod == .apiKey {
                    SecureField("Tailscale API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { credentialsChanged() }
                    Text("Generate at admin.tailscale.com > Settings > Keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("OAuth Client ID", text: $oauthClientID)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: oauthClientID) { credentialsChanged() }
                    SecureField("OAuth Client Secret", text: $oauthClientSecret)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: oauthClientSecret) { credentialsChanged() }
                    Text("Create OAuth client at admin.tailscale.com > Settings > OAuth clients")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("② Authentication")
            }

            // Step 3: Test
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Image(systemName: "network")
                        Text("Test Connection")
                    }
                }
                .disabled(testStatus.isTesting || !hasCredentials)

                if let status = testStatus {
                    switch status {
                    case .testing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting to Tailscale API...")
                                .font(.caption)
                        }
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            } header: {
                Text("③ Verify")
            }

            // Step 4: Save (only after successful test)
            Section {
                HStack {
                    Button("Save Locally") {
                        saveLocally()
                    }
                    .disabled(!connectionVerified)

                    Spacer()

                    Button("Save & Push to Server") {
                        Task { await pushToServer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connectionVerified || saveStatus.isSaving)
                    .help("Save locally and send credentials to the hydra server")
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
                            Text("Pushing to server...").font(.caption)
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
            apiKey = store.get(.tailscaleAPIKey)
            oauthClientID = store.get(.tailscaleOAuthClientID)
            oauthClientSecret = store.get(.tailscaleOAuthClientSecret)
            if !oauthClientID.isEmpty {
                authMethod = .oauth
            }
        }
    }

    private var hasCredentials: Bool {
        if authMethod == .apiKey {
            return !apiKey.isEmpty
        }
        return !oauthClientID.isEmpty && !oauthClientSecret.isEmpty
    }

    // MARK: - Test Connection

    private func testConnection() async {
        withAnimation { testStatus = .testing }

        let tn = tailnet.isEmpty ? "-" : tailnet
        let urlStr = "https://api.tailscale.com/api/v2/tailnet/\(tn)/devices"

        guard let url = URL(string: urlStr) else {
            withAnimation { testStatus = .error("Invalid tailnet name") }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        if authMethod == .apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            // OAuth: use client credentials as Basic auth
            let credentials = "\(oauthClientID):\(oauthClientSecret)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                withAnimation { testStatus = .error("No response") }
                return
            }

            if http.statusCode == 200 {
                // Parse device count from response
                if let json = try? JSONDecoder().decode(DevicesResponse.self, from: data) {
                    deviceCount = json.devices.count
                    withAnimation {
                        connectionVerified = true
                        testStatus = .success("Connected — \(json.devices.count) device(s) found in tailnet")
                    }
                } else {
                    withAnimation {
                        connectionVerified = true
                        testStatus = .success("Connected to Tailscale API")
                    }
                }
            } else if http.statusCode == 401 || http.statusCode == 403 {
                withAnimation { testStatus = .error("Authentication failed — check your API key or OAuth credentials") }
            } else {
                withAnimation { testStatus = .error("Tailscale API returned status \(http.statusCode)") }
            }
        } catch {
            withAnimation { testStatus = .error("Connection failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Save

    private func saveLocally() {
        store.set(.tailscaleAPIKey, value: authMethod == .apiKey ? apiKey : "")
        store.set(.tailscaleOAuthClientID, value: authMethod == .oauth ? oauthClientID : "")
        store.set(.tailscaleOAuthClientSecret, value: authMethod == .oauth ? oauthClientSecret : "")
        withAnimation { saveStatus = .savedLocally }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { saveStatus = nil }
        }
    }

    private func pushToServer() async {
        withAnimation { saveStatus = .saving }

        // Save locally first
        saveLocally()

        // Build config payload
        var config: [String: String] = ["tailnet": tailnet.isEmpty ? "-" : tailnet]
        if authMethod == .apiKey {
            config["api_key"] = apiKey
        } else {
            config["oauth_client_id"] = oauthClientID
            config["oauth_client_secret"] = oauthClientSecret
        }

        do {
            let url = URL(string: serverURL)!.appendingPathComponent("api/config/tailscale")
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let serverKey = store.get(.serverAPIKey)
            if !serverKey.isEmpty {
                request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
            }

            request.httpBody = try JSONEncoder().encode(config)
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

// MARK: - Helpers

private struct DevicesResponse: Decodable {
    let devices: [TailscaleDevice]

    struct TailscaleDevice: Decodable {
        let id: String
        let name: String
    }
}

private extension Optional where Wrapped == TailscaleSettingsTab.TestStatus {
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

private extension Optional where Wrapped == TailscaleSettingsTab.SaveStatus {
    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}
#endif
