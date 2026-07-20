import SwiftUI

/// iOS Orch detail — reuses the shared `OrchViewModel` (same data/logic as the
/// macOS `OrchDetailView`): info grid, node health, distributed execution, and
/// live worker processes. Pushed via `NavigationLink` from `OrchsScreen`
/// instead of a `NavigationSplitView` detail column.
struct OrchDetailScreen: View {
    let orch: Orch
    @ObservedObject var vm: OrchViewModel
    @Environment(\.theme) private var theme
    @State private var command = "nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text(orch.name)
                        .font(.title2.bold())
                    Spacer()
                    Text(orch.status)
                        .font(.caption.bold())
                        .foregroundStyle(orch.isRunning ? .green : .gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(orch.isRunning ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                        .clipShape(Capsule())
                }

                // Info
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    OrchInfoField(label: "Head Node", value: orch.coordinatorId)
                    OrchInfoField(label: "Workers", value: "\(orch.workerCount)")
                }

                // Health
                if let health = vm.health {
                    GroupBox("Node Health") {
                        ForEach(health.nodes) { node in
                            HStack {
                                Circle()
                                    .fill(node.healthy ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text(node.nodeId)
                                    .font(.caption.monospaced())
                                Text(node.role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let error = node.error, !error.isEmpty {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }

                // Execute
                GroupBox("Distributed Execution") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Command...", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            Task { await vm.execute(command: command) }
                        } label: {
                            Label(vm.isExecuting ? "Running..." : "Run on All Workers", systemImage: "play.fill")
                        }
                        .disabled(command.isEmpty || vm.isExecuting)

                        if let result = vm.executeResult {
                            Text("Results from \(result.worker_count) workers")
                                .font(.caption.bold())

                            ForEach(result.results) { r in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(r.deviceName)
                                            .font(.caption.bold())
                                        if !r.gpu.isEmpty {
                                            Text(r.gpu)
                                                .font(.caption)
                                                .foregroundStyle(.purple)
                                        }
                                        Spacer()
                                        Text(String(format: "%.0fms", r.durationMs))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(r.hasError ? (r.error ?? "") : r.output)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(r.hasError ? .red : .primary)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.quaternary)
                                        .clipShape(RoundedRectangle(cornerRadius: theme.controlRadius))
                                }
                            }
                        }
                    }
                }

                // Worker Processes (live)
                if !vm.workerStatuses.isEmpty {
                    GroupBox("Worker Processes (live · 5s)") {
                        ForEach(vm.workerStatuses) { worker in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle()
                                        .fill(worker.hasError ? .red : .green)
                                        .frame(width: 6, height: 6)
                                    Text(worker.shortName)
                                        .font(.caption.bold())
                                    if let gpu = worker.gpu {
                                        Text(gpu)
                                            .font(.caption2)
                                            .foregroundStyle(.purple)
                                    }
                                    Spacer()
                                    Text("\((worker.processes ?? []).count) processes")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                if worker.hasError {
                                    Text(worker.error ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                } else {
                                    // GPU processes
                                    if !worker.gpuProcesses.isEmpty {
                                        ForEach(worker.gpuProcesses) { proc in
                                            HStack(spacing: 4) {
                                                Image(systemName: "gpu")
                                                    .font(.caption2)
                                                    .foregroundStyle(.purple)
                                                Text(proc.command)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .lineLimit(1)
                                                Spacer()
                                                if let vram = proc.vramMB {
                                                    Text("\(vram)MB")
                                                        .font(.system(.caption2, design: .monospaced))
                                                        .foregroundStyle(.purple)
                                                }
                                                Text("PID \(proc.pid)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.leading, 12)
                                        }
                                    }

                                    // Top CPU processes
                                    ForEach(worker.cpuProcesses.prefix(3)) { proc in
                                        HStack(spacing: 4) {
                                            Image(systemName: "cpu")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                            Text(proc.command)
                                                .font(.system(.caption2, design: .monospaced))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(String(format: "%.1f%%", proc.cpuPercent))
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(proc.cpuPercent > 50 ? .red : .secondary)
                                        }
                                        .padding(.leading, 12)
                                    }
                                }

                                if worker.id != vm.workerStatuses.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                if let error = vm.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
        }
        .navigationTitle(orch.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.selectOrch(orch) }
        .onDisappear { vm.stopProcessPolling() }
    }
}

private struct OrchInfoField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }
}
