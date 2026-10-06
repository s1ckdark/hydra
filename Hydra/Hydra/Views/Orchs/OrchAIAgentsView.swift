import SwiftUI

#if os(macOS)
struct OrchAIAgentsSection: View {
    let orch: Orch
    var api: APIClient = .shared
    @EnvironmentObject private var chatVM: ChatViewModel
    @EnvironmentObject private var appState: AppState
    @State private var configuration = OrchAIAgents()
    @State private var isLoading = true
    @State private var error: String?
    @State private var isEditing = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AI Agents").font(.headline)
                    Spacer()
                    AgentActionControl(title: "Configure Agents", icon: "slider.horizontal.3",
                                       identifier: "orch-ai-agents-configure", enabled: !isLoading && error == nil) {
                        isEditing = true
                    }
                }
                if chatVM.runOrchestrationID == orch.id, let snapshot = chatVM.agentRun {
                    AgentTreeView(snapshot: snapshot, disconnected: chatVM.progressDisconnected || chatVM.progressUnavailable)
                        .frame(minHeight: 365)
                    Divider()
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                    AgentActionControl(title: "Retry", icon: "arrow.clockwise", identifier: "orch-ai-agents-retry") {
                        Task { await load() }
                    }
                } else {
                    if configuration.agents.isEmpty {
                        Text("Add agents with their own roles and models for this orchestration.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(configuration.agents) { agent in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.name).font(.subheadline.bold())
                                Text(agent.role).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                if let ref = agent.modelOverride {
                                    Text(configuration.label(for: ref)).font(.caption.monospaced())
                                } else {
                                    Text("Let head decide").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            AgentActionControl(title: "Open Agent Chat", icon: "bubble.left",
                                               identifier: "orch-agent-chat-\(agent.id)", enabled: chatVM.canSwitchAgent) {
                                let target = AgentChatTarget(orchestrationID: orch.id, orchestrationName: orch.name,
                                                             agent: agent, modelLabel: agent.modelOverride.map(configuration.label))
                                if chatVM.selectAgent(target) { appState.isChatDrawerOpen = true }
                            }
                        }
                        if agent.id != configuration.agents.last?.id { Divider() }
                    }
                    if !chatVM.canSwitchAgent {
                        Text("Run or cancel the pending plan and wait for the current request before switching agents.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !configuration.agents.isEmpty {
                        Text("Switching agents starts a new conversation.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .accessibilityIdentifier("orch-ai-agents-section")
        .task(id: orch.id) { await load() }
        .sheet(isPresented: $isEditing) {
            OrchAIAgentsEditor(orchestrationID: orch.id, orchestrationName: orch.name,
                               configuration: configuration, api: api) { configuration = $0 }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do { configuration = try await api.getOrchAIAgents(id: orch.id) }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

struct OrchAIAgentsEditor: View {
    let orchestrationID: String
    let orchestrationName: String
    let original: OrchAIAgents
    let api: APIClient
    let onSave: (OrchAIAgents) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OrchAIAgents
    @State private var isSaving = false
    @State private var error: String?

    init(orchestrationID: String, orchestrationName: String, configuration: OrchAIAgents,
         api: APIClient = .shared, onSave: @escaping (OrchAIAgents) -> Void) {
        self.orchestrationID = orchestrationID
        self.orchestrationName = orchestrationName
        self.original = configuration
        self.api = api
        self.onSave = onSave
        _draft = State(initialValue: configuration)
    }

    private var validationErrors: [String] { draft.validationErrors(original: original) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Configure AI Agents").font(.title2.bold())
                Text(orchestrationName).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionSection
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Head Model").font(.headline)
                            AIModelPicker(title: "Head Model", selection: $draft.headModel, configuration: draft,
                                          automaticTitle: "Use global AI settings", identifier: "orch-head-model")
                            Text("The head chooses a model from these connections using each agent's role and the task. An explicit agent model always wins.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    agentSection
                    if !validationErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(validationErrors, id: \.self) { message in
                                AppLocalizedText(message).font(.caption).foregroundStyle(.red)
                            }
                        }.accessibilityIdentifier("orch-ai-agents-validation")
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .padding(20)
            }
            .disabled(isSaving)
            Divider()
            HStack {
                Text("API keys are kept by the server. Leave a saved key blank to keep it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                AgentActionControl(title: "Cancel", icon: "xmark", identifier: "orch-ai-agents-cancel", enabled: !isSaving) {
                    clearDraftKeys()
                    dismiss()
                }
                AgentActionControl(title: "Save", icon: "checkmark", identifier: "orch-ai-agents-save",
                                   enabled: !isSaving && validationErrors.isEmpty) { Task { await save() } }
            }.padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 540, idealHeight: 720)
        .interactiveDismissDisabled(isSaving)
        .accessibilityIdentifier("orch-ai-agents-editor")
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Provider Connections").font(.headline)
                Spacer()
                AgentActionControl(title: "Add Connection", icon: "plus", identifier: "orch-add-connection") {
                    draft.connections.append(OrchAIConnection())
                }
            }
            Text("Enter exact model IDs available to your account. One connection can provide several models.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($draft.connections) { $connection in
                connectionCard($connection)
            }
        }
    }

    private func connectionCard(_ binding: Binding<OrchAIConnection>) -> some View {
        let connection = binding.wrappedValue
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Connection Name", text: binding.name)
                        .accessibilityIdentifier("orch-connection-name-\(connection.id)")
                    AgentActionControl(title: "Remove Connection", icon: "trash", identifier: "orch-remove-connection-\(connection.id)") {
                        draft.connections.removeAll { $0.id == connection.id }
                    }
                }
                Picker("Provider", selection: binding.provider) {
                    ForEach(AIProviderConfig.allProviders, id: \.self) { provider in
                        AppLocalizedText(AIProviderConfig.label(for: provider)).tag(provider)
                    }
                }
                .accessibilityIdentifier("orch-connection-provider-\(connection.id)")
                .onChange(of: connection.provider) { _, _ in binding.apiKey.wrappedValue = nil }
                TextField("Endpoint (optional for cloud providers)", text: binding.endpoint)
                    .accessibilityIdentifier("orch-connection-endpoint-\(connection.id)")
                SecureField("API Key", text: Binding(get: { binding.wrappedValue.apiKey ?? "" },
                                                    set: { binding.wrappedValue.apiKey = $0.isEmpty ? nil : $0 }))
                    .accessibilityIdentifier("orch-connection-key-\(connection.id)")
                if connection.canKeepStoredKey(from: original) {
                    Text("Saved key available. Leave blank to keep it.").font(.caption).foregroundStyle(.secondary)
                } else if AIProviderConfig.isCloudProvider(connection.provider) {
                    Text("An API key is required for this connection.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Model IDs").font(.subheadline.bold())
                ForEach(connection.models.indices, id: \.self) { index in
                    HStack {
                        TextField("Exact model ID", text: Binding(get: {
                            binding.wrappedValue.models.indices.contains(index) ? binding.wrappedValue.models[index] : ""
                        }, set: {
                            guard binding.wrappedValue.models.indices.contains(index) else { return }
                            binding.wrappedValue.models[index] = $0
                        }))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("orch-connection-model-\(connection.id)-\(index)")
                        AgentActionControl(title: "Remove Model", icon: "minus.circle", identifier: "orch-remove-model-\(connection.id)-\(index)") {
                            guard binding.wrappedValue.models.indices.contains(index) else { return }
                            binding.wrappedValue.models.remove(at: index)
                        }
                    }
                }
                AgentActionControl(title: "Add Model", icon: "plus", identifier: "orch-add-model-\(connection.id)") {
                    binding.wrappedValue.models.append("")
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(6)
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                AgentActionControl(title: "Add Agent", icon: "plus", identifier: "orch-add-agent") {
                    draft.agents.append(OrchAIAgent())
                }
            }
            ForEach($draft.agents) { $agent in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Agent Name", text: $agent.name)
                                .accessibilityIdentifier("orch-agent-name-\(agent.id)")
                            AgentActionControl(title: "Remove Agent", icon: "trash", identifier: "orch-remove-agent-\(agent.id)") {
                                draft.agents.removeAll { $0.id == agent.id }
                            }
                        }
                        TextField("Role instructions", text: $agent.role, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("orch-agent-role-\(agent.id)")
                        AIModelPicker(title: "Agent Model", selection: $agent.modelOverride, configuration: draft,
                                      automaticTitle: "Let head decide", identifier: "orch-agent-model-\(agent.id)")
                    }
                    .textFieldStyle(.roundedBorder).padding(6)
                }
            }
        }
    }

    private func clearDraftKeys() {
        for index in draft.connections.indices { draft.connections[index].apiKey = nil }
    }

    private func save() async {
        guard !isSaving, validationErrors.isEmpty else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let saved = try await api.saveOrchAIAgents(id: orchestrationID, configuration: draft)
            clearDraftKeys()
            onSave(saved)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct AIModelPicker: View {
    let title: String
    @Binding var selection: AIModelReference?
    let configuration: OrchAIAgents
    let automaticTitle: String
    let identifier: String

    var body: some View {
        Picker(AppLocalization.string(title), selection: $selection) {
            AppLocalizedText(automaticTitle).tag(Optional<AIModelReference>.none)
            if let selection, !configuration.contains(selection) {
                Text(AppLocalization.string("Unavailable model") + " · " + selection.model)
                    .tag(Optional(selection))
            }
            ForEach(Array(Set(configuration.modelReferences)).sorted {
                configuration.label(for: $0) < configuration.label(for: $1)
            }, id: \.self) { reference in
                Text(configuration.label(for: reference)).tag(Optional(reference))
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif

/// Uses the app's gesture-based controls to avoid the macOS DesignLibrary
/// _ButtonGesture executor crash, while retaining an accessibility action.
struct AgentActionControl: View {
    let title: String
    let icon: String
    let identifier: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Label(AppLocalization.string(title), systemImage: icon)
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(AppLocalization.string(title))
            .accessibilityIdentifier(identifier)
            .accessibilityAction { if enabled { action() } }
            .disabled(!enabled)
    }
}
