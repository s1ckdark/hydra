import SwiftUI

struct ChatAgentContextView: View {
    @EnvironmentObject private var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = vm.selectedAgent {
                Text(target.agent.name).font(.subheadline.bold())
                    .accessibilityIdentifier("chat-active-agent")
                Text(target.orchestrationName).font(.caption).foregroundStyle(.secondary)
                if let selection = vm.modelSelection {
                    ChatModelSelectionLabel(selection: selection)
                } else if let model = target.modelLabel {
                    Text(model).font(.caption.monospaced())
                    Text("Explicit model").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Head will choose a model when you send.").font(.caption).foregroundStyle(.secondary)
                }
                AgentActionControl(title: "Default Hydra Chat", icon: "bubble.left.and.bubble.right",
                                   identifier: "chat-default-agent", enabled: vm.canSwitchAgent) {
                    vm.selectAgent(nil)
                }
                if !vm.canSwitchAgent {
                    Text("Run or cancel the pending plan and wait for the current request before switching agents.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Default Hydra Chat").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("chat-agent-context")
    }
}

struct ChatModelSelectionLabel: View {
    let selection: AgentModelSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppLocalization.string(AIProviderConfig.label(for: selection.provider)) + " · " + selection.model)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("chat-active-model")
            AppLocalizedText(selection.source == "override" ? "Explicit model" : "Chosen by head")
                .font(.caption2).foregroundStyle(.secondary)
            if let reason = selection.reason, !reason.isEmpty {
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(3).help(reason)
            }
        }
    }
}
