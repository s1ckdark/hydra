import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Server connection status
                ServerStatusBanner(status: vm.serverStatus, version: vm.serverVersion)

                // Offline device alert
                if !vm.offlineDevices.isEmpty {
                    OfflineAlert(devices: vm.offlineDevices)
                }

                // Summary cards
                HStack(spacing: 16) {
                    SummaryCard(
                        title: "Devices",
                        value: "\(vm.onlineDevices.count)/\(vm.devices.count)",
                        subtitle: "online",
                        icon: "desktopcomputer",
                        color: .blue
                    )
                    SummaryCard(
                        title: "GPU Nodes",
                        value: "\(vm.gpuDevices.count)",
                        subtitle: "\(vm.totalGPUs) GPUs total",
                        icon: "gpu",
                        color: .purple
                    )
                    SummaryCard(
                        title: "Orchs",
                        value: "\(vm.orchs.count)",
                        subtitle: "\(vm.runningOrchs.count) running",
                        icon: "server.rack",
                        color: .green
                    )
                    SummaryCard(
                        title: "Tasks",
                        value: "\(vm.runningTasks.count)",
                        subtitle: "\(vm.tasks.count) total",
                        icon: "list.bullet.clipboard",
                        color: .orange
                    )
                }

                HStack(spacing: 16) {
                    // Left column
                    VStack(spacing: 16) {
                        // GPU utilization gauge
                        GPUGaugeSection(vm: vm)

                        // Running Orch status
                        if !vm.runningOrchs.isEmpty {
                            RunningOrchsSection(orchs: vm.runningOrchs, devices: vm.devices)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Right column
                    VStack(spacing: 16) {
                        // Recent tasks
                        RecentTasksSection(tasks: vm.recentTasks, devices: vm.devices)

                        // Quick command
                        QuickCommandSection(vm: vm)
                    }
                    .frame(maxWidth: .infinity)
                }

                if let error = vm.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let lastRefresh = vm.lastRefresh {
                    Text("Last updated: \(lastRefresh.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem {
                Button(action: { Task { await vm.load() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .navigationTitle("Dashboard")
        .onAppear { vm.startPolling(interval: 15) }
        .onDisappear { vm.stopPolling() }
    }
}

// MARK: - Server Status Banner

struct ServerStatusBanner: View {
    let status: DashboardViewModel.ServerStatus
    let version: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
            if !version.isEmpty {
                Text("v\(version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .disconnected: return .red
        case .unknown: return .gray
        }
    }

    private var statusText: String {
        switch status {
        case .connected: return "Server Connected"
        case .disconnected: return "Server Disconnected"
        case .unknown: return "Checking..."
        }
    }
}

// MARK: - Offline Alert

struct OfflineAlert: View {
    let devices: [Device]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(devices.count) device\(devices.count > 1 ? "s" : "") offline:")
                .font(.caption)
                .fontWeight(.medium)
            Text(devices.map(\.shortName).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - GPU Gauge

struct GPUGaugeSection: View {
    @ObservedObject var vm: DashboardViewModel

    var body: some View {
        GroupBox {
            if vm.gpuNodes.isEmpty {
                Text("No GPU data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 12) {
                    // Aggregate gauge
                    HStack(spacing: 20) {
                        GaugeRing(
                            value: vm.avgGPUUtilization,
                            label: "Utilization",
                            color: gaugeColor(vm.avgGPUUtilization)
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            StatRow(label: "Avg Util", value: String(format: "%.0f%%", vm.avgGPUUtilization))
                            StatRow(label: "VRAM", value: String(format: "%.1f / %.1f GB", vm.totalVRAMUsedGB, vm.totalVRAMTotalGB))
                            StatRow(label: "GPUs", value: "\(vm.totalGPUs) across \(vm.gpuNodes.count) nodes")
                        }
                    }

                    Divider()

                    // Per-node bars
                    ForEach(vm.gpuNodes) { node in
                        if let gpus = node.gpus, !gpus.isEmpty {
                            ForEach(gpus) { gpu in
                                HStack(spacing: 8) {
                                    Text(node.deviceName.components(separatedBy: ".").first ?? node.deviceName)
                                        .font(.caption)
                                        .frame(width: 80, alignment: .leading)
                                        .lineLimit(1)
                                    ProgressView(value: gpu.utilizationPercent, total: 100)
                                        .tint(gaugeColor(gpu.utilizationPercent))
                                    Text(String(format: "%.0f%%", gpu.utilizationPercent))
                                        .font(.system(.caption2, design: .monospaced))
                                        .frame(width: 30, alignment: .trailing)
                                    Text("\(gpu.temperatureC)°C")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(gpu.temperatureC > 80 ? .red : gpu.temperatureC > 60 ? .orange : .secondary)
                                        .frame(width: 30, alignment: .trailing)
                                }
                            }
                        } else if node.hasError {
                            HStack {
                                Text(node.deviceName.components(separatedBy: ".").first ?? node.deviceName)
                                    .font(.caption)
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                                    .font(.caption2)
                                Text("error")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("GPU Status (live)", systemImage: "gpu")
        }
    }

    private func gaugeColor(_ value: Double) -> Color {
        if value > 80 { return .red }
        if value > 50 { return .orange }
        return .green
    }
}

struct GaugeRing: View {
    let value: Double
    let label: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: value / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: value)
            VStack(spacing: 0) {
                Text(String(format: "%.0f%%", value))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(label)
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Running Orchs

struct RunningOrchsSection: View {
    let orchs: [Orch]
    let devices: [Device]

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                ForEach(orchs) { orch in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text(orch.name)
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            Text(orch.mode)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        HStack(spacing: 4) {
                            Text("Head:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(deviceName(orch.coordinatorId))
                                .font(.caption2)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(orch.workerCount) workers")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if orch.id != orchs.last?.id {
                        Divider()
                    }
                }
            }
        } label: {
            Label("Running Orchs", systemImage: "server.rack")
        }
    }

    private func deviceName(_ id: String) -> String {
        devices.first { $0.id == id }?.shortName ?? id.prefix(8).description
    }
}

// MARK: - Recent Tasks

struct RecentTasksSection: View {
    let tasks: [NagaTask]
    let devices: [Device]

    var body: some View {
        GroupBox {
            if tasks.isEmpty {
                Text("No tasks yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(spacing: 6) {
                    ForEach(tasks) { task in
                        HStack(spacing: 8) {
                            Image(systemName: task.statusIcon)
                                .foregroundStyle(colorForStatus(task.statusColor))
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.type)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    if let deviceId = task.assignedDeviceId {
                                        Text(deviceName(deviceId))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(task.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text(task.status)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(colorForStatus(task.statusColor))
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        } label: {
            Label("Recent Tasks", systemImage: "list.bullet.clipboard")
        }
    }

    private func deviceName(_ id: String) -> String {
        devices.first { $0.id == id }?.shortName ?? id.prefix(8).description
    }

    private func colorForStatus(_ s: String) -> Color {
        switch s {
        case "green": return .green
        case "red": return .red
        case "blue": return .blue
        case "orange": return .orange
        default: return .gray
        }
    }
}

// MARK: - Quick Command

struct QuickCommandSection: View {
    @ObservedObject var vm: DashboardViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Device picker
                HStack {
                    Text("Target:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $vm.quickCommandDeviceId) {
                        Text("Select device...").tag(nil as String?)
                        ForEach(vm.onlineDevices) { device in
                            Text(device.shortName).tag(device.id as String?)
                        }
                    }
                    .labelsHidden()
                }

                // Command input
                HStack {
                    TextField("Command...", text: $vm.quickCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    Button {
                        Task { await vm.executeQuickCommand() }
                    } label: {
                        Image(systemName: vm.isExecutingQuickCommand ? "hourglass" : "play.fill")
                    }
                    .disabled(vm.quickCommand.isEmpty || vm.quickCommandDeviceId == nil || vm.isExecutingQuickCommand)
                }

                // Result
                if let result = vm.quickCommandResult {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.hasError ? "Error" : "Output")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(result.hasError ? .red : .primary)
                            Spacer()
                            Text(String(format: "%.0fms", result.durationMs))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(result.hasError ? (result.error ?? "") : result.output)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(result.hasError ? .red : .primary)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .lineLimit(8)
                    }
                }
            }
        } label: {
            Label("Quick Command", systemImage: "terminal")
        }
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}
