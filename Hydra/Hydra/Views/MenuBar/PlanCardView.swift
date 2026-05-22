import SwiftUI

/// Renders an LLM-proposed plan with per-action rows and Run / Cancel
/// buttons. Driven entirely by the ChatViewModel; no API calls of its
/// own.
struct PlanCardView: View {
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
                            .clipShape(RoundedRectangle(cornerRadius: 4))
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

    /// One-line summary of an action's args for the row label.
    private func argsSummary(_ args: AnyCodable) -> String {
        guard let dict = args.value as? [String: Any] else { return "" }
        return dict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}
