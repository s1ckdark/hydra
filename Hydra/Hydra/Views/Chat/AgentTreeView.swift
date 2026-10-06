import SwiftUI

/// Renders only nodes and edges reported for this run. Layout and connectors
/// are shared by the orchestration section and expanded chat tree.
struct AgentTreeView: View {
    let snapshot: AgentRunSnapshot
    var disconnected = false
    @Environment(\.theme) private var theme
    @State private var selectedNodeID: String?
    @State private var currentStepRequest = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Agent Tree", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                if !snapshot.activeNodes.isEmpty {
                    AgentActionControl(title: "Current step", icon: "scope",
                                       identifier: "agent-tree-current-step", action: requestCurrentStep)
                        .focusable()
                        .onKeyPress(.return) { requestCurrentStep(); return .handled }
                        .onKeyPress(.space) { requestCurrentStep(); return .handled }
                }
                AppLocalizedText(snapshot.phaseLabel).font(.caption.bold())
                    .accessibilityIdentifier("agent-tree-phase")
            }
            if disconnected {
                Label("Connection interrupted. The latest state is unknown.", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Follow the arrows from left to right. Dashed arrows show delegation.")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.nodes.isEmpty {
                Text("No agent activity has been reported yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let layout = AgentTreeLayout(snapshot: snapshot, minimumWidth: geometry.size.width)
                    ScrollViewReader { proxy in
                      ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            ForEach(layout.branches) { branch in
                                RoundedRectangle(cornerRadius: theme.cardRadius)
                                    .fill(Color.accentColor.opacity(0.035))
                                    .overlay(alignment: .topLeading) {
                                        Text(branch.title).font(.caption2).foregroundStyle(.secondary)
                                            .padding(.horizontal, 10).padding(.top, 5)
                                    }
                                    .frame(width: branch.frame.width, height: branch.frame.height)
                                    .position(x: branch.frame.midX, y: branch.frame.midY)
                                    .accessibilityHidden(true)
                            }
                            ForEach(layout.connectors) { connector in
                                AgentTreeArrow(points: connector.points)
                                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5,
                                                                                           dash: connector.edge.kind == "delegation" ? [5, 4] : []))
                                    .accessibilityHidden(true)
                            }
                            nodeGrid(layout: layout)
                        }
                        .frame(width: layout.size.width, height: max(geometry.size.height, layout.size.height), alignment: .topLeading)
                    }
                    .accessibilityIdentifier("agent-tree-scroll")
                    .onChange(of: currentStepRequest) { _, _ in
                        if let id = snapshot.activeNodes.last?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                    }
                }
                .frame(minHeight: 235)
            }
            if let selectedNodeID, let node = snapshot.nodes.first(where: { $0.id == selectedNodeID }) {
                nodeDetails(node)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-tree")
        .onChange(of: snapshot.runID) { _, _ in selectedNodeID = nil }
    }

    private func requestCurrentStep() {
        currentStepRequest = UUID()
    }

    /// Real grid cells give ScrollViewReader each card's actual bounds.
    /// Positioning cards in the arrow canvas makes their scroll target inherit
    /// the canvas bounds, so Current step would scroll to the canvas center.
    /// All cell sizes and gaps below come from the same pure layout as arrows.
    private func nodeGrid(layout: AgentTreeLayout) -> some View {
        let columns = Array(Set(layout.nodes.map { $0.frame.minX })).sorted()
        let rows = Array(Set(layout.nodes.map { $0.frame.minY })).sorted()
        let cardSize = layout.nodes.first?.frame.size ?? .zero
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { column in
                        Group {
                            if let placed = layout.nodes.first(where: { $0.frame.minX == column.element && $0.frame.minY == row.element }),
                               let node = snapshot.nodes.first(where: { $0.id == placed.id }) {
                                AgentTreeNodeCard(node: node, displayStep: placed.displayStep, selected: selectedNodeID == node.id)
                                    .frame(width: placed.frame.width, height: placed.frame.height)
                                    .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius))
                                    .onTapGesture { selectedNodeID = node.id }
                                    .focusable()
                                    .onKeyPress(.return) { selectedNodeID = node.id; return .handled }
                                    .onKeyPress(.space) { selectedNodeID = node.id; return .handled }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { selectedNodeID = node.id }
                                    .id(node.id)
                            } else {
                                Color.clear.frame(width: cardSize.width, height: cardSize.height)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.trailing, column.offset + 1 < columns.count ? columns[column.offset + 1] - column.element - cardSize.width : 0)
                        .padding(.bottom, row.offset + 1 < rows.count ? rows[row.offset + 1] - row.element - cardSize.height : 0)
                    }
                }
            }
        }
        .padding(.leading, columns.first ?? 0)
        .padding(.top, rows.first ?? 0)
    }

    private func nodeDetails(_ node: AgentRunNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack {
                Text(node.title).font(.subheadline.bold())
                AppLocalizedText(node.status.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let duration = node.duration {
                    Text(AppLocalization.format("Duration: %.1f s", duration)).font(.caption.monospacedDigit())
                }
            }
            if let message = node.message, !message.isEmpty {
                Text(AppLocalization.string(message)).font(.caption).textSelection(.enabled)
            }
            if let action = node.actionType {
                Text(action).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("agent-tree-node-details")
    }
}

private struct AgentTreeArrow: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.move(to: CGPoint(x: last.x - 7, y: last.y - 5))
            path.addLine(to: last)
            path.addLine(to: CGPoint(x: last.x - 7, y: last.y + 5))
        }
    }
}

private struct AgentTreeNodeCard: View {
    let node: AgentRunNode
    let displayStep: Int?
    let selected: Bool
    @Environment(\.theme) private var theme

    private var statusColor: Color {
        switch node.status {
        case .running: return .accentColor
        case .waiting: return .orange
        case .completed: return .green
        case .failed: return .red
        case .unknown: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if node.kind == "root" {
                    Text("Task").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(AppLocalization.format("Step %d", displayStep ?? 1)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if node.status == .running {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                }
                AppLocalizedText(node.status.label)
                    .font(.caption2.bold()).foregroundStyle(statusColor)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: theme.chipRadius))
            }
            Text(AppLocalization.string(node.title)).font(.subheadline.bold()).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let model = node.model, !model.isEmpty {
                Text(model).font(.caption.monospaced()).lineLimit(2)
            }
            if let provider = node.provider, !provider.isEmpty {
                AppLocalizedText(AIProviderConfig.label(for: provider)).font(.caption2).foregroundStyle(.secondary)
            } else if let action = node.actionType {
                Text(action).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardRadius)
                .strokeBorder(selected || node.status == .running ? Color.accentColor : theme.borderColor.opacity(0.7),
                              lineWidth: selected || node.status == .running ? 2 : max(0.75, theme.borderWidth))
        }
        .shadow(color: theme.cardShadow?.color ?? .clear,
                radius: theme.cardShadow?.radius ?? 0, y: theme.cardShadow?.y ?? 0)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-tree-node-\(node.id)")
    }
}

/// Small drawer/full-chat entry point. The expanded sheet observes the same
/// view model, so progress continues while it is open.
struct AgentTreeChatSummary: View {
    @EnvironmentObject private var vm: ChatViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let run = vm.agentRun {
                HStack {
                    Label("Agent Tree", systemImage: "point.3.connected.trianglepath.dotted").font(.caption.bold())
                    Spacer()
                    AppLocalizedText(run.phaseLabel).font(.caption2).foregroundStyle(.secondary)
                }
                if !run.activeNodes.isEmpty {
                    ForEach(run.activeNodes) { node in
                        HStack(spacing: 6) {
                            if node.status == .running { ProgressView().controlSize(.mini) }
                            Text(AppLocalization.string(node.title)).font(.caption).lineLimit(1)
                            AppLocalizedText(node.status.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                AgentActionControl(title: "Expand Agent Tree", icon: "arrow.up.left.and.arrow.down.right",
                                   identifier: "chat-expand-agent-tree") { expanded = true }
            }
            if vm.progressDisconnected {
                Text("Connection interrupted. The latest state is unknown.").font(.caption2).foregroundStyle(.orange)
            } else if vm.progressUnavailable {
                Text("Live progress is unavailable from this server.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("chat-agent-tree-summary")
        .sheet(isPresented: $expanded) { AgentTreeSheet().environmentObject(vm) }
    }
}

private struct AgentTreeSheet: View {
    @EnvironmentObject private var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            if let snapshot = vm.agentRun {
                AgentTreeView(snapshot: snapshot, disconnected: vm.progressDisconnected || vm.progressUnavailable)
            } else {
                Text("No agent activity has been reported yet.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                AgentActionControl(title: "Close", icon: "xmark", identifier: "agent-tree-close") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 900, minHeight: 430, idealHeight: 570)
        .accessibilityIdentifier("agent-tree-sheet")
    }
}
