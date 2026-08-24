import SwiftUI

#if os(iOS)
struct iOSAIRoleOverridesView: View {
    var body: some View {
        Form {
            iOSRoleOverrideSection(title: "Head Selection", role: "head")
            iOSRoleOverrideSection(title: "Task Scheduling", role: "schedule")
            iOSRoleOverrideSection(title: "Capacity Estimation", role: "capacity")
            iOSRoleOverrideSection(title: "Chat Agent", role: "chat")
        }
        .navigationTitle("Per-role Overrides")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One Section per role. The Toggle decides whether to inherit the default
/// provider; when off, the same provider/key/endpoint/model fields appear
/// inline. Storage keys (`aiRole_<role>_*`) match what macOS RoleOverrideView
/// uses, so per-role state is shared across platforms when both apps run on
/// non-secret settings use UserDefaults while API keys stay in Keychain.
private struct iOSRoleOverrideSection: View {
    let title: String
    let role: String

    @AppStorage private var useDefault: Bool
    @AppStorage private var provider: String
    @AppStorage private var endpoint: String
    @AppStorage private var model: String
    @State private var apiKey: String = ""

    private let store = CredentialStore.shared

    init(title: String, role: String) {
        self.title = title
        self.role = role
        self._useDefault = AppStorage(wrappedValue: true,  "aiRole_\(role)_useDefault")
        self._provider   = AppStorage(wrappedValue: "",    "aiRole_\(role)_provider")
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
                        .onChange(of: apiKey) { persistAPIKey() }
                }
                if AIProviderConfig.localProviders.contains(provider) || provider == "zai" {
                    TextField("Endpoint", text: $endpoint, prompt: Text("http://localhost:11434"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                if !provider.isEmpty {
                    TextField("Model (optional)", text: $model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
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
        .onAppear {
            if let key = CredentialStore.Key.aiRoleAPIKey(for: role) {
                apiKey = store.get(key)
            }
        }
    }

    private func persistAPIKey() {
        guard let key = CredentialStore.Key.aiRoleAPIKey(for: role) else { return }
        store.set(key, value: apiKey)
    }
}
#endif
