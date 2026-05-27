import SwiftUI

/// Renders an LLM-proposed plan with Run / Cancel buttons. Two modes:
/// - full (default): per-action list with args, used in the Chat tab
/// - compact: intent + first action label only, used in the menubar
struct PlanCardView: View {
    let plan: AgentPlan
    let message: String?
    let isThinking: Bool
    let compact: Bool
    let onRun: () -> Void
    let onCancel: () -> Void

    init(
        plan: AgentPlan,
        message: String?,
        isThinking: Bool,
        compact: Bool = false,
        onRun: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.plan = plan
        self.message = message
        self.isThinking = isThinking
        self.compact = compact
        self.onRun = onRun
        self.onCancel = onCancel
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.intent)
                    .font(.caption.bold())
                    .lineLimit(compact ? 1 : nil)
                    .truncationMode(.tail)

                if !compact, let message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if compact {
                    Text(plan.compactActionLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Divider()
                    ForEach(plan.actions) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(action.type)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 4)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(argsSummary(action.args))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
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

    /// One-line summary of an action's args for the full-mode row label.
    private func argsSummary(_ args: AnyCodable) -> String {
        guard let dict = args.value as? [String: Any] else { return "" }
        return dict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}
