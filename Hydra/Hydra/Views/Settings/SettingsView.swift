import SwiftUI

#if os(macOS)
enum SettingsSection: String, CaseIterable, Identifiable {
    case server, tailscale, ai, terminal, appearance

    var id: Self { self }

    var title: String {
        switch self {
        case .server: return "Server"
        case .tailscale: return "Tailscale"
        case .ai: return "AI"
        case .terminal: return "Terminal"
        case .appearance: return "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .server: return "server.rack"
        case .tailscale: return "network"
        case .ai: return "brain"
        case .terminal: return "apple.terminal"
        case .appearance: return "paintbrush"
        }
    }
}

/// Shared by the dashboard tab and the standalone Settings window.
struct SettingsNavigationView: View {
    @Binding var selection: SettingsSection
    var isActive: Bool = true
    var onOpen: () -> Void = {}
    var onExpand: () -> Void = {}
    @State private var isExpanded = false
    @FocusState private var focusedSection: SettingsSection?

    var body: some View {
        HStack(spacing: 4) {
            settingsButton
            if isExpanded {
                HStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        sectionButton(section)
                            .id(section)
                    }
                }
                .onAppear(perform: onExpand)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .id("settings-navigation")
        .onExitCommand { isExpanded = false }
        .onChange(of: isActive) { _, active in
            if !active { isExpanded = false }
        }
    }

    private var settingsButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "gearshape")
            AppLocalizedText("Settings")
            Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                .font(.caption2)
        }
        .font(.callout)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Match the custom tab bar's gesture path; avoid the macOS Button crash.
        .onTapGesture(perform: toggleMenu)
        .focusable()
        .onKeyPress(.return) { toggleMenu(); return .handled }
        .onKeyPress(.space) { toggleMenu(); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings-menu")
        .accessibilityAction { toggleMenu() }
    }

    private func sectionButton(_ section: SettingsSection) -> some View {
        HStack(spacing: 5) {
            Image(systemName: section.icon)
            AppLocalizedText(section.title)
        }
        .font(.callout)
        .foregroundStyle(selection == section ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selection == section ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { select(section) }
        .focusable()
        .focused($focusedSection, equals: section)
        .onKeyPress(.return) { select(section); return .handled }
        .onKeyPress(.space) { select(section); return .handled }
        .onKeyPress(.rightArrow) { moveFocus(from: section, by: 1); return .handled }
        .onKeyPress(.leftArrow) { moveFocus(from: section, by: -1); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == section ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("settings-section-\(section.rawValue)")
        .accessibilityAction { select(section) }
    }

    private func toggleMenu() {
        onOpen()
        isExpanded.toggle()
    }

    private func select(_ section: SettingsSection) {
        selection = section
    }

    private func moveFocus(from section: SettingsSection, by offset: Int) {
        let sections = SettingsSection.allCases
        guard let index = sections.firstIndex(of: section) else { return }
        focusedSection = sections[(index + offset + sections.count) % sections.count]
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .server

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    SettingsNavigationView(selection: $selection, onExpand: {
                        proxy.scrollTo("settings-navigation", anchor: .leading)
                    })
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            SettingsContentView(selection: selection)
        }
        .frame(width: 560, height: 520)
    }
}

struct SettingsContentView: View {
    let selection: SettingsSection
    @State private var visitedSections: Set<SettingsSection> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: selection.icon)
                AppLocalizedText(selection.title)
            }
            .font(.headline)
            .padding()

            // Keep visited panes mounted so draft credentials and connection-test
            // results survive section changes, as they did in the original TabView.
            ZStack {
                ForEach(SettingsSection.allCases) { section in
                    if selection == section || visitedSections.contains(section) {
                        content(for: section)
                            .opacity(selection == section ? 1 : 0)
                            .disabled(selection != section)
                            .allowsHitTesting(selection == section)
                            .accessibilityHidden(selection != section)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection, initial: true) { previous, current in
            visitedSections.formUnion([previous, current])
        }
    }

    @ViewBuilder private func content(for section: SettingsSection) -> some View {
        switch section {
        case .server: ServerSettingsTab()
        case .tailscale: TailscaleSettingsTab()
        case .ai: AISettingsTab()
        case .terminal: TerminalSettingsTab()
        case .appearance: AppearanceSettingsTab()
        }
    }
}

// MARK: - Terminal Settings

private struct TerminalSettingsTab: View {
    @AppStorage("terminalPersistViaTmux") private var persistViaTmux = false
    @ObservedObject private var settingsStore = TerminalSettingsStore.shared
    @EnvironmentObject private var dashboardVM: DashboardViewModel

    var body: some View {
        Form {
            TerminalSettingsForm(settings: settingsStore.globalBinding)

            Section {
                Toggle("tmux 세션 지속", isOn: $persistViaTmux)
                Text("""
                켜면 터미널을 열 때 원격 노드의 tmux 세션(`hydra`)에 자동으로 부착합니다. \
                앱을 종료하거나 연결이 끊겨도 원격에서 실행 중이던 작업이 살아있고, \
                다시 접속하면 그 자리 그대로 이어집니다.

                • 노드에 tmux가 설치되어 있어야 합니다 — 없거나 부착에 실패하면 일반 셸로 폴백합니다.
                • 앱에서 세션을 닫아도 원격 tmux 세션은 유지됩니다. 완전히 끝내려면 tmux 안에서 `exit`를 입력하세요 (일반 셸로 돌아옵니다).
                • 로그인 셸이 tmux를 자동 실행하는 노드에서는 중첩될 수 있으니 끄는 것을 권장합니다.

                이 설정과 무관하게, 열려 있던 세션 목록은 항상 저장되어 앱 재시작 시 자동 복원됩니다.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("세션 지속")
            }

            TerminalNodeOverridesSection(store: settingsStore, nodeName: { id in
                dashboardVM.devices.first { $0.id == id }?.displayName ?? id
            })
        }
        .formStyle(.grouped)
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
                connectionStatus = AppLocalization.string("Failed: non-200 response")
                return
            }
            if let json = try? JSONDecoder().decode([String: String].self, from: data),
               let status = json["status"] {
                connectionStatus = "\(AppLocalization.string("Connected —")) \(status)"
            }
        } catch {
            connectionStatus = "\(AppLocalization.string("Error:")) \(error.localizedDescription)"
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
            withAnimation { testStatus = .error(AppLocalization.string("Invalid tailnet name")) }
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
                        testStatus = .success(AppLocalization.string("Connected to Tailscale API"))
                    }
                }
            } else if http.statusCode == 401 || http.statusCode == 403 {
                withAnimation { testStatus = .error(AppLocalization.string("Authentication failed — check your API key or OAuth credentials")) }
            } else {
                withAnimation { testStatus = .error("\(AppLocalization.string("Tailscale API returned status")) \(http.statusCode)") }
            }
        } catch {
            withAnimation { testStatus = .error("\(AppLocalization.string("Connection failed:")) \(error.localizedDescription)") }
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
