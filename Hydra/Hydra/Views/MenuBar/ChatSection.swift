import SwiftUI

/// Menubar chat surface. Read-only: status, last result, and a compact
/// PlanCard for pending-plan approval. The actual conversation lives in
/// the dashboard's Chat tab; the "Open Chat →" button routes there.
struct ChatSection: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var appState: AppState

    /// Called when the user wants to open the dashboard window with the
    /// Chat tab active. Hosted by `MenuBarView`, which owns the AppKit
    /// activation dance.
    var onOpenChat: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            statusLine

            if let last = lastRelevantTurn {
                resultLine(turn: last)
            }

            if let plan = vm.pendingPlan {
                PlanCardView(
                    plan: plan,
                    message: vm.pendingPlanMessage,
                    isThinking: vm.isThinking,
                    compact: true,
                    onRun:    { Task { await vm.runPendingPlan() } },
                    onCancel: { vm.cancelPendingPlan() }
                )
            }

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button(action: onOpenChat) {
                HStack(spacing: 4) {
                    Text("Open Chat")
                    Image(systemName: "arrow.right")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if let plan = vm.pendingPlan {
            return "Plan pending (\(plan.actions.count) action\(plan.actions.count == 1 ? "" : "s"))"
        }
        if vm.isThinking { return "Thinking…" }
        if vm.error != nil { return "Error" }
        return "Idle"
    }

    private var statusColor: Color {
        if vm.pendingPlan != nil { return .orange }
        if vm.isThinking { return .accentColor }
        if vm.error != nil { return .red }
        return .secondary
    }

    private var lastRelevantTurn: ChatTurn? {
        vm.turns.last { ["assistant_ask", "assistant_plan", "system_result"].contains($0.role) }
    }

    private func resultLine(turn: ChatTurn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(roleGlyph(for: turn.role))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(turn.content)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func roleGlyph(for role: String) -> String {
        switch role {
        case "assistant_ask":  return "?"
        case "assistant_plan": return "▶"
        case "system_result":  return "✓"
        default:               return "•"
        }
    }
}
