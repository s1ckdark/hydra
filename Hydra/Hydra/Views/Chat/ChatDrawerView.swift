import SwiftUI

/// Right-side chat drawer hosted by ContentView. Reuses the app-scope
/// ChatViewModel so the menubar's passive ChatSection reflects the same
/// state. The drawer composes a context preamble via ChatContextProvider
/// at send time, scoped to whichever tab/selection is active.
struct ChatDrawerView: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesArea
            Divider()
            inputBar
        }
        .frame(maxHeight: .infinity)
        .background(.background)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text("Chat")
                .font(.headline)
            Spacer()
            Button {
                openWindow(id: "chat-expanded")
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Expand to full window")
            Button {
                appState.isChatDrawerOpen = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close drawer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var messagesArea: some View {
        Group {
            if vm.turns.isEmpty && vm.pendingPlan == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.turns) { turn in
                                DrawerTurnRow(turn: turn).id(turn.id)
                            }
                            if let plan = vm.pendingPlan {
                                PlanCardView(
                                    plan: plan,
                                    message: vm.pendingPlanMessage,
                                    isThinking: vm.isThinking,
                                    compact: true,
                                    onRun:    { Task { await vm.runPendingPlan() } },
                                    onCancel: { vm.cancelPendingPlan() }
                                ).id("pendingPlan")
                            }
                            if let err = vm.error {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: vm.turns.count) { _, _ in
                        if let last = vm.turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Ask Hydra")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Active tab is auto-included as context.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Ask…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { submit() }
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
            if vm.isThinking { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func submit() {
        let msg = draft
        draft = ""
        let preamble = ChatContextProvider.snapshot(
            for: appState.activeTab,
            dashboardVM: dashboardVM,
            selection: currentSelection()
        )
        Task { await vm.send(msg, contextPreamble: preamble) }
    }

    private func currentSelection() -> ChatContextProvider.Selection {
        ChatContextProvider.Selection(
            device: appState.selectedDeviceId.flatMap { id in
                dashboardVM.devices.first { $0.id == id }
            },
            orch: appState.selectedOrchId.flatMap { id in
                dashboardVM.orchs.first { $0.id == id }
            },
            task: appState.selectedTaskId.flatMap { id in
                SavedTaskStore.shared.tasks.first { $0.id == id }
            }
        )
    }
}

/// Narrow-width row variant. Same content as ChatTabView's row but
/// stacked vertically so the role badge doesn't steal width from the
/// message text in a 350-px drawer.
private struct DrawerTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(roleLabel)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(turn.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
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
