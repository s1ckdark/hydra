import SwiftUI

/// Chat panel that lives inside the menubar popover. Scrolls history,
/// inline-renders the pending plan card, and owns the input field.
struct ChatSection: View {
    @StateObject private var vm = ChatViewModel()
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.turns) { turn in
                        ChatTurnRow(turn: turn)
                    }
                    if let plan = vm.pendingPlan {
                        PlanCardView(
                            plan: plan,
                            message: vm.pendingPlanMessage,
                            isThinking: vm.isThinking,
                            onRun:    { Task { await vm.runPendingPlan() } },
                            onCancel: { vm.cancelPendingPlan() }
                        )
                    }
                    if let err = vm.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                TextField("Ask Hydra…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
            }
            if vm.isThinking {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("thinking…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func submit() {
        let msg = draft
        draft = ""
        Task { await vm.send(msg) }
    }
}

private struct ChatTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(roleSymbol)
                .font(.caption2)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(turn.content)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
    private var roleSymbol: String {
        switch turn.role {
        case "user":            return "›"
        case "assistant_ask":   return "?"
        case "assistant_plan":  return "▶"
        case "system_result":   return "✓"
        default:                return "•"
        }
    }
}
