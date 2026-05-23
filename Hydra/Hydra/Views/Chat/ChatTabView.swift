import SwiftUI

/// Full chat surface, hosted in the dashboard window's Chat tab.
/// Mirrors the agent flow the menubar used to host inline, with room
/// to breathe and a focused input.
struct ChatTabView: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            if vm.turns.isEmpty && vm.pendingPlan == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.turns) { turn in
                                ChatTurnRow(turn: turn)
                                    .id(turn.id)
                            }
                            if let plan = vm.pendingPlan {
                                PlanCardView(
                                    plan: plan,
                                    message: vm.pendingPlanMessage,
                                    isThinking: vm.isThinking,
                                    compact: false,
                                    onRun:    { Task { await vm.runPendingPlan() } },
                                    onCancel: { vm.cancelPendingPlan() }
                                )
                                .id("pendingPlan")
                            }
                            if let err = vm.error {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onChange(of: vm.turns.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: vm.pendingPlan == nil) { _, _ in
                        scrollToBottom(proxy)
                    }
                }
            }

            inputBar
        }
        .padding(.bottom, 8)
        .onAppear { inputFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Ask Hydra anything")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("e.g. \"list devices\" or \"create an orch on home-mac\"")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        HStack {
            TextField("Ask Hydra…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { submit() }
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
            if vm.isThinking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    private func submit() {
        let msg = draft
        draft = ""
        Task { await vm.send(msg) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if vm.pendingPlan != nil {
            withAnimation { proxy.scrollTo("pendingPlan", anchor: .bottom) }
            return
        }
        if let last = vm.turns.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

private struct ChatTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(roleSymbol)
                .font(.caption.bold())
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(turn.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
