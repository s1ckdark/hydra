import SwiftUI

/// iOS Chat tab. Reuses the shared ChatViewModel (server-backed AI agent)
/// with a fresh instance scoped to this tab — no drawer/open-window
/// paradigm since this is a dedicated full-screen tab, not a macOS
/// side-drawer.
struct ChatScreen: View {
    @StateObject private var vm = ChatViewModel()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messagesArea
                Divider()
                inputBar
            }
            .navigationTitle("Chat")
        }
    }

    private var messagesArea: some View {
        Group {
            if vm.turns.isEmpty && vm.pendingPlan == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(vm.turns) { turn in
                                ChatTurnRow(turn: turn).id(turn.id)
                            }
                            if let plan = vm.pendingPlan {
                                ChatPlanCardView(
                                    plan: plan,
                                    message: vm.pendingPlanMessage,
                                    isThinking: vm.isThinking,
                                    onRun: { Task { await vm.runPendingPlan() } },
                                    onCancel: { vm.cancelPendingPlan() }
                                ).id("pendingPlan")
                            }
                            if let err = vm.error {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if vm.isThinking {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .id("thinking")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: vm.turns.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: vm.pendingPlan == nil) { _, _ in
                        scrollToBottom(proxy)
                    }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if vm.pendingPlan != nil {
                proxy.scrollTo("pendingPlan", anchor: .bottom)
            } else if let last = vm.turns.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Ask Hydra")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Ask a question or request an action.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isThinking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submit() {
        let msg = draft
        draft = ""
        Task { await vm.send(msg, contextPreamble: nil) }
    }
}

/// One row in the chat history. Adapted from ChatDrawerView's
/// DrawerTurnRow for a full-width iOS tab.
private struct ChatTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(roleLabel)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(turn.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.body)
        }
    }
    private var roleLabel: String {
        switch turn.role {
        case "user":            return "YOU"
        case "assistant_ask":   return "ASK"
        case "assistant_plan":  return "PLAN"
        case "system_result":   return "RESULT"
        default:                return turn.role.uppercased()
        }
    }
}

/// Renders an LLM-proposed pending plan with Run / Cancel actions.
/// Adapted from Hydra/Views/MenuBar/PlanCardView.swift (full mode) for
/// the iOS Chat tab.
private struct ChatPlanCardView: View {
    @Environment(\.theme) private var theme
    let plan: AgentPlan
    let message: String?
    let isThinking: Bool
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.intent)
                    .font(.caption.bold())

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                ForEach(plan.actions) { action in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(action.type)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 4)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: theme.chipRadius))
                        Text(argsSummary(action.args))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Run", action: onRun)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isThinking)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func argsSummary(_ args: AnyCodable) -> String {
        guard let dict = args.value as? [String: Any] else { return "" }
        return dict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}
