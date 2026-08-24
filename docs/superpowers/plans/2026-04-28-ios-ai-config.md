# iOS AI Config — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a drill-down "AI" Settings tab to iOS so an admin can rotate or disable the Hydra server's AI provider key from a phone, with full feature parity to macOS.

**Architecture:** Extract a cross-platform `AIProviderConfig` utility for provider labels, cloud/local membership, and test-connection request building. Both new iOS views (`iOSAIConfigView`, `iOSAIRoleOverridesView`) and the existing macOS `AISettingsTab` call into it, so domain logic lives in one place and platform-specific SwiftUI stays in its own file.

**Tech Stack:** SwiftUI, Swift Package Manager (no Xcode test target today — Task 1 adds one), Apple Foundation framework only (no third-party deps), `XCTest` for unit tests.

**Spec:** [docs/superpowers/specs/2026-04-27-ios-ai-config-design.md](../specs/2026-04-27-ios-ai-config-design.md)

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `Hydra/Package.swift` | Modify | add `testTarget(name: "HydraTests", path: "Tests")` |
| `Hydra/Tests/AIProviderConfigTests.swift` | Create | XCTest cases for provider labels + request building |
| `Hydra/Hydra/Services/AIProviderConfig.swift` | Create | cross-platform utility (labels, sets, request builder) |
| `Hydra/Hydra/Views/Settings/AISettingsTab.swift` | Modify | replace inline label/sets/request-build with `AIProviderConfig` |
| `Hydra/Hydra/Views/iOS/iOSAIRoleOverridesView.swift` | Create | per-role overrides drill-down (leaf) |
| `Hydra/Hydra/Views/iOS/iOSAIConfigView.swift` | Create | main AI config drill-down (uses `iOSAIRoleOverridesView`) |
| `Hydra/Hydra/Views/iOS/iOSSettingsView.swift` | Modify | new `Section("AI")` with `NavigationLink` to `iOSAIConfigView` |

Working directory for every task: `/Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config`

---

## Task 1: `AIProviderConfig` utility + test target

**Files:**
- Modify: `Hydra/Package.swift`
- Create: `Hydra/Tests/AIProviderConfigTests.swift`
- Create: `Hydra/Hydra/Services/AIProviderConfig.swift`

- [ ] **Step 1: Add test target to `Hydra/Package.swift`**

Replace `targets:` block (currently has only the executable target):

```swift
    targets: [
        .executableTarget(
            name: "Hydra",
            path: "Hydra",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "HydraTests",
            dependencies: ["Hydra"],
            path: "Tests"
        ),
    ]
```

- [ ] **Step 2: Run `swift build` to confirm test target wires up**

```bash
cd Hydra && swift build 2>&1 | tail -3
```

Expected: `Build complete!` (test target present but no tests yet).

- [ ] **Step 3: Write failing tests**

Create `Hydra/Tests/AIProviderConfigTests.swift`:

```swift
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
        // Endpoint that cannot be parsed as URL after appending /v1/models.
        let req = AIProviderConfig.testConnectionRequest(provider: "ollama", apiKey: "", endpoint: " ")
        XCTAssertNil(req)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd Hydra && swift test --filter AIProviderConfigTests 2>&1 | tail -10
```

Expected: compile failure — `AIProviderConfig` undefined.

- [ ] **Step 5: Create the utility implementation**

Create `Hydra/Hydra/Services/AIProviderConfig.swift`:

```swift
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
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd Hydra && swift test --filter AIProviderConfigTests 2>&1 | tail -15
```

Expected: 11 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config
git add Hydra/Package.swift \
        Hydra/Hydra/Services/AIProviderConfig.swift \
        Hydra/Tests/AIProviderConfigTests.swift
git commit -m "feat(swift): add AIProviderConfig cross-platform utility + test target

Pure-function utility that owns provider labels, cloud/local classification,
and test-connection request shapes for iOS and macOS Settings views. New
HydraTests target hosts XCTest cases — first time the project gets unit-
testable code.

11 tests cover all 6 supported providers and the negative paths (unknown
provider, empty/whitespace endpoint, unparseable URL)."
```

---

## Task 2: Refactor macOS `AISettingsTab` to call `AIProviderConfig`

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AISettingsTab.swift`

This task removes the now-duplicated label / cloud-set / test-URL logic from the macOS view in favour of the new utility. Behaviour is identical; the diff is mostly deletion.

- [ ] **Step 1: Read the current macOS view to confirm exact lines to replace**

```bash
cd Hydra && grep -n "static let cloudProviders\|static let localProviders\|isCloudProvider\|label(for id\|case \"claude\":" Hydra/Views/Settings/AISettingsTab.swift | head -25
```

Confirm the locations of `cloudProviders`/`localProviders` static sets, `label(for:)` helper, and the testConnection switch statement.

- [ ] **Step 2: Replace inline static sets with utility references**

In `AISettingsTab.swift`, find these lines (near the top of the struct):

```swift
    /// Cloud providers require an API key; local providers require an endpoint URL.
    static let cloudProviders: Set<String> = ["claude", "openai", "zai"]
    static let localProviders: Set<String> = ["ollama", "lmstudio", "openai_compatible"]

    private var isCloudProvider: Bool { Self.cloudProviders.contains(provider) }

    private func isCloudProviderID(_ id: String) -> Bool {
        return Self.cloudProviders.contains(id)
    }
```

Replace with:

```swift
    private var isCloudProvider: Bool { AIProviderConfig.isCloudProvider(provider) }

    private func isCloudProviderID(_ id: String) -> Bool {
        AIProviderConfig.isCloudProvider(id)
    }
```

- [ ] **Step 3: Replace inline `label(for:)` helper**

Find:

```swift
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
```

Replace with one line:

```swift
    private func label(for id: String) -> String { AIProviderConfig.label(for: id) }
```

- [ ] **Step 4: Replace the testConnection request-building switch**

In `testConnection() async`, find:

```swift
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
```

Replace with:

```swift
        guard let req = AIProviderConfig.testConnectionRequest(provider: provider, apiKey: apiKey, endpoint: endpoint) else {
            withAnimation { testStatus = .error("Invalid provider or endpoint") }
            return
        }
```

- [ ] **Step 5: Verify Swift build**

```bash
cd Hydra && swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 6: Smoke-run the macOS app**

```bash
cd Hydra
pkill -f ".build/.*Hydra$" 2>/dev/null || true
sleep 1
swift run Hydra > /tmp/hydra-mac.log 2>&1 &
sleep 4
pgrep -f ".build/.*Hydra$" >/dev/null && echo "macOS app still running" || echo "macOS app crashed (check /tmp/hydra-mac.log)"
pkill -f ".build/.*Hydra$" 2>/dev/null || true
```

Expected: app runs (Provider picker / Test Connection still work via utility).

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config
git add Hydra/Hydra/Views/Settings/AISettingsTab.swift
git commit -m "refactor(swift): macOS AISettingsTab uses AIProviderConfig utility

Replace inline cloud/local sets, label switch, and testConnection
request builder with calls to the new cross-platform AIProviderConfig.
Behaviour identical; ~50 lines move out of the view file. Sets up
iOS to share the same domain logic in subsequent tasks without
duplication or drift."
```

---

## Task 3: `iOSAIRoleOverridesView` (leaf drill-down)

**Files:**
- Create: `Hydra/Hydra/Views/iOS/iOSAIRoleOverridesView.swift`

Built first because `iOSAIConfigView` (Task 4) NavigationLinks into it.

- [ ] **Step 1: Create the file**

Create `Hydra/Hydra/Views/iOS/iOSAIRoleOverridesView.swift`:

```swift
import SwiftUI

#if os(iOS)
struct iOSAIRoleOverridesView: View {
    var body: some View {
        Form {
            iOSRoleOverrideSection(title: "Head Selection", role: "head")
            iOSRoleOverrideSection(title: "Task Scheduling", role: "schedule")
            iOSRoleOverrideSection(title: "Capacity Estimation", role: "capacity")
        }
        .navigationTitle("Per-role Overrides")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One Section per role. The Toggle decides whether to inherit the default
/// provider; when off, the same provider/key/endpoint/model fields appear
/// inline. Storage keys (`aiRole_<role>_*`) match what macOS RoleOverrideView
/// uses, so per-role state is shared across platforms when both apps run on
/// the same iCloud account/UserDefaults domain.
private struct iOSRoleOverrideSection: View {
    let title: String
    let role: String

    @AppStorage private var useDefault: Bool
    @AppStorage private var provider: String
    @AppStorage private var apiKey: String
    @AppStorage private var endpoint: String
    @AppStorage private var model: String

    init(title: String, role: String) {
        self.title = title
        self.role = role
        self._useDefault = AppStorage(wrappedValue: true,  "aiRole_\(role)_useDefault")
        self._provider   = AppStorage(wrappedValue: "",    "aiRole_\(role)_provider")
        self._apiKey     = AppStorage(wrappedValue: "",    "aiRole_\(role)_apikey")
        self._endpoint   = AppStorage(wrappedValue: "",    "aiRole_\(role)_endpoint")
        self._model      = AppStorage(wrappedValue: "",    "aiRole_\(role)_model")
    }

    var body: some View {
        Section {
            Toggle("Use default provider", isOn: $useDefault)

            if !useDefault {
                Picker("Provider", selection: $provider) {
                    Text("(unset)").tag("")
                    ForEach(AIProviderConfig.allProviders, id: \.self) { id in
                        Text(AIProviderConfig.label(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)

                if AIProviderConfig.isCloudProvider(provider) {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                } else if !provider.isEmpty {
                    TextField("Endpoint", text: $endpoint, prompt: Text("http://localhost:11434"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                }

                if !provider.isEmpty {
                    TextField("Model (optional)", text: $model)
                        .autocapitalization(.none)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if useDefault {
                Text("Inherits the default provider configured above.")
                    .font(.caption2)
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Verify build**

```bash
cd Hydra && swift build 2>&1 | tail -3
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config
git add Hydra/Hydra/Views/iOS/iOSAIRoleOverridesView.swift
git commit -m "feat(ios): iOSAIRoleOverridesView for per-role provider overrides

Three Section()s — Head Selection, Task Scheduling, Capacity Estimation.
Each carries a Toggle('Use default provider') + collapsible provider /
key / endpoint / model fields when the toggle is off. Storage keys mirror
the macOS RoleOverrideView pattern (aiRole_<role>_*) so the same UserDefaults
shape is reused.

Leaf view in the iOS drill-down chain — iOSAIConfigView (next task)
NavigationLinks here."
```

---

## Task 4: `iOSAIConfigView` (main drill-down)

**Files:**
- Create: `Hydra/Hydra/Views/iOS/iOSAIConfigView.swift`

- [ ] **Step 1: Create the file**

Create `Hydra/Hydra/Views/iOS/iOSAIConfigView.swift`:

```swift
import SwiftUI

#if os(iOS)
struct iOSAIConfigView: View {
    @AppStorage("serverURL") private var serverURL = "http://localhost:8080"
    @AppStorage("aiDefaultProvider") private var provider: String = "claude"
    @AppStorage("aiDefaultEndpoint") private var endpoint: String = ""
    @AppStorage("aiDefaultModel") private var model: String = ""

    @State private var apiKey: String = ""
    @State private var connectionVerified = false
    @State private var testStatus: TestStatus?
    @State private var saveStatus: SaveStatus?

    private let store = CredentialStore.shared

    enum TestStatus {
        case testing
        case success(String)
        case error(String)
    }

    enum SaveStatus {
        case saving
        case saved
        case error(String)
    }

    private var isCloudProvider: Bool { AIProviderConfig.isCloudProvider(provider) }
    private var hasCredentials: Bool {
        if isCloudProvider { return !apiKey.isEmpty }
        return !endpoint.isEmpty
    }

    var body: some View {
        Form {
            providerSection
            verifySection
            advancedSection
            saveSection
        }
        .navigationTitle("AI Provider")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = store.get(.aiDefaultAPIKey)
        }
    }

    // MARK: - ① Provider (Default)

    @ViewBuilder
    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(AIProviderConfig.allProviders, id: \.self) { id in
                    Text(AIProviderConfig.label(for: id)).tag(id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: provider) { credentialsChanged() }

            if isCloudProvider {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .onChange(of: apiKey) { credentialsChanged() }
            } else {
                TextField("Endpoint", text: $endpoint, prompt: Text("http://localhost:11434"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .onChange(of: endpoint) { credentialsChanged() }
            }

            TextField("Model (optional)", text: $model)
                .autocapitalization(.none)
                .onChange(of: model) { credentialsChanged() }
        } header: {
            Text("AI Provider (Default)")
        }
    }

    // MARK: - ② Verify

    @ViewBuilder
    private var verifySection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Image(systemName: "bolt.horizontal.circle")
                    Text("Test Connection")
                }
            }
            .disabled(!hasCredentials || testStatus.isTesting)

            if let status = testStatus {
                switch status {
                case .testing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Testing…").font(.caption)
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
            Text("Verify")
        }
    }

    // MARK: - ③ Advanced (drill-down)

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            NavigationLink("Per-role overrides") {
                iOSAIRoleOverridesView()
            }
        } footer: {
            Text("Override the default provider for specific roles (Head Selection, Task Scheduling, Capacity Estimation).")
                .font(.caption)
        }
    }

    // MARK: - ④ Save & Push

    @ViewBuilder
    private var saveSection: some View {
        Section {
            Button("Save & Push to Server") {
                Task { await pushToServer() }
            }
            .disabled(!connectionVerified || saveStatus.isSaving)
        } header: {
            Text("Save")
        } footer: {
            if !connectionVerified {
                Text("Test the connection first before saving.")
                    .font(.caption)
            }
            if let status = saveStatus {
                switch status {
                case .saving:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Pushing to server…").font(.caption)
                    }
                case .saved:
                    Label("Pushed to server", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                case .error(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            }
        }
    }

    // MARK: - Actions

    private func credentialsChanged() {
        connectionVerified = false
        testStatus = nil
        saveStatus = nil
    }

    private func testConnection() async {
        withAnimation { testStatus = .testing }

        guard let req = AIProviderConfig.testConnectionRequest(provider: provider, apiKey: apiKey, endpoint: endpoint) else {
            withAnimation { testStatus = .error("Invalid provider or endpoint") }
            return
        }

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

    private func pushToServer() async {
        withAnimation { saveStatus = .saving }
        // Persist API key to Keychain inline so saveStatus stays .saving
        // for the duration of the network round-trip.
        store.set(.aiDefaultAPIKey, value: isCloudProvider ? apiKey : "")

        var defaultPayload: [String: String] = [
            "provider": provider,
            "model":    model,
        ]
        if isCloudProvider {
            defaultPayload["api_key"] = apiKey
        } else {
            defaultPayload["endpoint"] = endpoint
        }

        var body: [String: Any] = ["default": defaultPayload]
        // Read role overrides from UserDefaults (matching aiRole_<role>_* keys
        // populated by iOSAIRoleOverridesView). When useDefault is true (or
        // unset), skip; otherwise include a per-role override block.
        let defaults = UserDefaults.standard
        let roleKeys = [
            ("head_selection", "head"),
            ("task_scheduling", "schedule"),
            ("capacity_estimation", "capacity"),
        ]
        for (jsonKey, slug) in roleKeys {
            let raw = defaults.object(forKey: "aiRole_\(slug)_useDefault")
            let useDefault = (raw as? Bool) ?? true
            if useDefault { continue }
            let roleProvider = defaults.string(forKey: "aiRole_\(slug)_provider") ?? ""
            let roleAPIKey   = defaults.string(forKey: "aiRole_\(slug)_apikey") ?? ""
            let roleEndpoint = defaults.string(forKey: "aiRole_\(slug)_endpoint") ?? ""
            let roleModel    = defaults.string(forKey: "aiRole_\(slug)_model") ?? ""
            if roleProvider.isEmpty { continue }
            var override: [String: String] = ["provider": roleProvider, "model": roleModel]
            if AIProviderConfig.isCloudProvider(roleProvider) {
                override["api_key"] = roleAPIKey
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
            withAnimation { saveStatus = .saved }
        } catch {
            withAnimation { saveStatus = .error(error.localizedDescription) }
        }
    }
}

private extension Optional where Wrapped == iOSAIConfigView.TestStatus {
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

private extension Optional where Wrapped == iOSAIConfigView.SaveStatus {
    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}
#endif
```

- [ ] **Step 2: Verify build**

```bash
cd Hydra && swift build 2>&1 | tail -3
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config
git add Hydra/Hydra/Views/iOS/iOSAIConfigView.swift
git commit -m "feat(ios): iOSAIConfigView main AI Settings drill-down

Four sections matching the macOS AISettingsTab layout: Provider (Default),
Verify, Advanced (NavigationLink to iOSAIRoleOverridesView), Save & Push.
Single 'Save & Push to Server' button — iOS use case is always
server-bound, no separate 'Save Locally' button. Keychain write happens
inline inside pushToServer so saveStatus stays .saving for the entire
PUT round-trip (mirrors PR #1 round-5 fix in the macOS view).

URL force-unwrap is guarded — invalid serverURL surfaces in the save
status banner instead of crashing the UI."
```

---

## Task 5: Wire `iOSSettingsView` Section "AI" + NavigationLink

**Files:**
- Modify: `Hydra/Hydra/Views/iOS/iOSSettingsView.swift`

- [ ] **Step 1: Read existing iOSSettingsView to find the right insertion point**

```bash
cd Hydra && grep -n "Section\|navigationTitle\|^struct iOSSettingsView" Hydra/Views/iOS/iOSSettingsView.swift | head -10
```

Confirm the existing Section ordering (Server, Capabilities, Device, About). The new "AI" Section goes between Server and Capabilities so the most-used items live near the top.

- [ ] **Step 2: Insert the AI Section + NavigationLink**

Find this block (Server section) in `iOSSettingsView.swift`:

```swift
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)

                    SecureField("API Key (for external access)", text: $apiKey)
                }
```

Add immediately after that closing brace:

```swift
                Section {
                    NavigationLink {
                        iOSAIConfigView()
                    } label: {
                        HStack {
                            Image(systemName: "brain")
                            Text("AI Provider")
                        }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("Configure the AI provider Hydra uses for task scheduling and head election.")
                        .font(.caption)
                }
```

- [ ] **Step 3: Verify build**

```bash
cd Hydra && swift build 2>&1 | tail -3
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config
git add Hydra/Hydra/Views/iOS/iOSSettingsView.swift
git commit -m "feat(ios): iOSSettingsView gains AI Section with drill-down link

New Section between Server and Capabilities: NavigationLink labeled
'AI Provider' (with brain SF Symbol) pushes iOSAIConfigView. Footer
explains the section's purpose."
```

---

## Task 6: Final verification

**Files:** none (read-only)

- [ ] **Step 1: Full Swift build (release mode for sanity)**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config/Hydra
swift build -c release 2>&1 | tail -5
```

Expected: clean release build.

- [ ] **Step 2: Run all tests**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config/Hydra
swift test 2>&1 | tail -15
```

Expected: 11 `AIProviderConfigTests` pass.

- [ ] **Step 3: Run macOS app and exercise the AI tab**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config/Hydra
swift run Hydra > /tmp/hydra-mac.log 2>&1 &
sleep 5
echo "App PID: $(pgrep -f '.build/.*Hydra$')"
```

Open `Cmd+,` Preferences → AI tab. Confirm:
- Provider picker still shows 6 entries with `(cloud)`/`(local)` hints
- Switching to Ollama swaps the API Key field for an Endpoint field
- Test Connection still works against a reachable provider

Kill the app:

```bash
pkill -f ".build/.*Hydra$" 2>/dev/null
```

- [ ] **Step 4: Document the manual iOS verification checklist for reviewers**

iOS Simulator verification (each reviewer with a Mac runs this manually since CI doesn't run simulator tests):

1. Build for iOS Simulator: `swift build` (or via Xcode opening `Package.swift`).
2. Run iOS scheme in an iOS 17+ Simulator.
3. Settings tab → tap **AI Provider** — drill-down occurs.
4. Picker Claude → Ollama → field swaps API Key ↔ Endpoint.
5. Empty Endpoint → Test Connection disabled.
6. Enter `http://localhost:11434` → Test Connection — expect banner.
7. Tap **Per-role overrides** → drill-down → toggle "Use default" off for Head Selection → enter override values → back → **Save & Push to Server**.
8. On the server: `curl http://127.0.0.1:8080/api/config/ai` shows the new `default` and `head_selection` values, secrets masked.
9. Type `localhost:8080` (no scheme) into Server URL → Save & Push → expect "Invalid server URL" banner, no crash.
10. SecureField Password Autofill: with 1Password installed, tap API Key field → confirm autofill suggestion appears.

- [ ] **Step 5: Push branch + open PR (no commit step here — branch already has 5 commits from Tasks 1-5)**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/ios-ai-config
git push origin claude/ios-ai-config 2>&1 | tail -3

gh pr create --title "feat(ios): AI Settings tab with cross-platform AIProviderConfig utility" --body "$(cat <<'PRBODY'
## Summary

Brings macOS AISettingsTab parity to iOS via a NavigationLink drill-down: \`iOSSettingsView → iOSAIConfigView → iOSAIRoleOverridesView\`. Use case: rotate or disable the server's AI provider key from a phone.

A new cross-platform \`AIProviderConfig\` utility owns provider labels, cloud/local classification, and test-connection request building. Both the new iOS views and the existing macOS \`AISettingsTab\` call into it, so domain logic has a single source of truth and SwiftUI state stays platform-specific.

## Files

| Change | Files |
|---|---|
| New utility (cross-platform, tested) | \`Hydra/Hydra/Services/AIProviderConfig.swift\` + \`Hydra/Tests/AIProviderConfigTests.swift\` |
| New iOS UI | \`Hydra/Hydra/Views/iOS/iOSAIConfigView.swift\`, \`iOSAIRoleOverridesView.swift\` |
| iOS Settings entry | \`Hydra/Hydra/Views/iOS/iOSSettingsView.swift\` (new Section "AI") |
| macOS refactor | \`Hydra/Hydra/Views/Settings/AISettingsTab.swift\` (call utility instead of inline copies) |
| SPM test target | \`Hydra/Package.swift\` (first \`testTarget\` in this package) |

## Test plan

- [x] \`swift test\` — 11 \`AIProviderConfigTests\` cover all 6 providers + negative paths (unknown / empty endpoint / unparseable URL).
- [x] \`swift build\` (debug + release) clean.
- [x] macOS app smoke: AI tab still works (provider picker, field swap, Test Connection).
- [ ] iOS Simulator manual verification (10-step checklist in plan): drill-down, field swap, Test Connection, Per-role overrides, Save & Push, force-unwrap guard, Password Autofill.

## Out of scope (intentionally deferred)

- iOS-local AI / on-device inference (Foundation Models SDK).
- iPad split-view-specific layouts (NavigationStack auto-adapts).
- Lock Screen widget / Siri Shortcuts intents.
- Apple Watch companion.
- Localization (English strings only).
- \`always_consult\` toggle in iOS UI — server PUT preserves omitted value (PR #1 round-3 fix), and the operational case for changing it from a phone is rare.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PRBODY
)"
```

---

## Self-review

**Spec coverage check:**

| Spec section | Plan task |
|---|---|
| Goals (drill-down, parity, shared utility, iOS UX touches) | Tasks 3–5 |
| File structure (new files / modified files / reused) | All tasks; matches "File map" table at top of plan |
| `AIProviderConfig` definition | Task 1 (Step 5) |
| iOSAIConfigView §1–§4 sections | Task 4 (Step 1) |
| iOSAIRoleOverridesView 3 role sections | Task 3 (Step 1) |
| Failure & lifecycle (URL guard, override preservation) | Task 4 (Step 1, `pushToServer` URL guard + omit-when-default) |
| Testing — unit tests | Task 1 (Step 3, 11 tests) |
| Testing — manual verification | Task 6 (Step 4 checklist) |
| Reuse (APIClient, CredentialStore) | No new APIClient method needed — Task 4 inlines the PUT (matches macOS pattern); CredentialStore reused with existing `aiDefaultAPIKey` key. |
| Migration / rollout | Net-additive; no migration concern beyond what the plan already shows. |

**Placeholder scan:** No "TBD" / "implement later" / "similar to Task N" patterns. All step bodies have concrete code or commands.

**Type consistency:** `AIProviderConfig.allProviders`, `cloudProviders`, `localProviders`, `isCloudProvider`, `label(for:)`, `testConnectionRequest(provider:apiKey:endpoint:)` all match between Task 1 implementation and Tasks 3, 4 callers. The macOS refactor in Task 2 uses the same names.

**One known nuance** logged for the implementer: the `iOSRoleOverridesView` introduces a new `aiRole_<role>_apikey` UserDefaults key (cloud providers need a separate key field). The macOS `RoleOverrideView` historically reused the `endpoint` slot for the API key — that's documented in PR #1's round-2 review as tech debt. The iOS implementation chooses the cleaner separate-key approach. macOS push semantics (`AISettingsTab.swift:280-287`) read from `aiRole_<role>_endpoint` for cloud overrides; **out of scope for this PR** to fix that across both platforms — flag for follow-up if it becomes a real issue. The iOS-only iOSAIConfigView reads from `aiRole_<role>_apikey` so iOS behaves correctly on its own; if a user edits an override on iOS and re-pushes from macOS later, the macOS view would not see the API key. Acceptable trade-off for v1.
