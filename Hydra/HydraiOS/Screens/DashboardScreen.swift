import SwiftUI

/// iOS dashboard — reuses the shared `DashboardViewModel` (same data/logic as
/// the macOS `DashboardView`), laid out for a single-column iPhone/iPad width
/// instead of macOS's 2-column HStacks.
struct DashboardScreen: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DashboardServerStatusBanner(status: dashboardVM.serverStatus, version: dashboardVM.serverVersion)

                    if !dashboardVM.offlineDevices.isEmpty {
                        DashboardOfflineAlert(devices: dashboardVM.offlineDevices)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        DashboardSummaryCard(
                            title: "Devices",
                            value: "\(dashboardVM.onlineDevices.count)/\(dashboardVM.devices.count)",
                            subtitle: "online",
                            icon: "desktopcomputer",
                            color: .blue
                        )
                        DashboardSummaryCard(
                            title: "GPU Nodes",
                            value: "\(dashboardVM.gpuDevices.count)",
                            subtitle: "\(dashboardVM.totalGPUs) GPUs total",
                            icon: "gpu",
                            color: .purple
                        )
                        DashboardSummaryCard(
                            title: "Orchs",
                            value: "\(dashboardVM.orchs.count)",
                            subtitle: "\(dashboardVM.runningOrchs.count) running",
                            icon: "server.rack",
                            color: .green
                        )
                        DashboardSummaryCard(
                            title: "Tasks",
                            value: "\(dashboardVM.runningTasks.count)",
                            subtitle: "\(dashboardVM.tasks.count) total",
                            icon: "list.bullet.clipboard",
                            color: .orange
                        )
                    }

                    DashboardDevicesOverviewSection(vm: dashboardVM)

                    DashboardGPUSection(vm: dashboardVM)

                    if !dashboardVM.runningOrchs.isEmpty {
                        DashboardRunningOrchsSection(orchs: dashboardVM.runningOrchs, devices: dashboardVM.devices)
                    }

                    DashboardRecentTasksSection(tasks: dashboardVM.recentTasks, devices: dashboardVM.devices)

                    DashboardQuickCommandSection(vm: dashboardVM)

                    if let error = dashboardVM.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    if let lastRefresh = dashboardVM.lastRefresh {
                        Text("Last updated: \(lastRefresh.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
            .overlay {
                if dashboardVM.isLoading && dashboardVM.devices.isEmpty && dashboardVM.orchs.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.opacity(0.7))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: dashboardVM.isLoading)
            .refreshable { await dashboardVM.load(force: true) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if dashboardVM.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await dashboardVM.load(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .navigationTitle("대시보드")
            .task {
                await dashboardVM.load()
                dashboardVM.startPolling(interval: 5)
            }
            .onDisappear { dashboardVM.stopPolling() }
        }
    }
}

// MARK: - Server Status Banner

private struct DashboardServerStatusBanner: View {
    @Environment(\.theme) private var theme
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
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
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

private struct DashboardOfflineAlert: View {
    @Environment(\.theme) private var theme
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
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
    }
}

// MARK: - Summary Card

private struct DashboardSummaryCard: View {
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
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .cardStyle()
    }
}

// MARK: - Devices overview (compact cards)

private struct DashboardDevicesOverviewSection: View {
    @ObservedObject var vm: DashboardViewModel

    private var utilByDevice: [String: Double] {
        var map: [String: Double] = [:]
        for node in vm.gpuNodes {
            guard let gpus = node.gpus, !gpus.isEmpty else { continue }
            map[node.deviceId] = gpus.reduce(0) { $0 + $1.utilizationPercent } / Double(gpus.count)
        }
        return map
    }

    private var sortedDevices: [Device] {
        vm.devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            return a.shortName.localizedCaseInsensitiveCompare(b.shortName) == .orderedAscending
        }
    }

    var body: some View {
        GroupBox {
            if vm.devices.isEmpty {
                Text("No devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(sortedDevices) { device in
                        DashboardDeviceCard(
                            device: device,
                            gpuUtil: utilByDevice[device.id],
                            metrics: vm.metricsByDevice[device.id]
                        )
                    }
                }
            }
        } label: {
            Label("Devices", systemImage: "desktopcomputer")
        }
    }
}

private struct DashboardDeviceCard: View {
    @Environment(\.theme) private var theme
    let device: Device
    let gpuUtil: Double?
    let metrics: DeviceMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(device.isOnline ? .green : .red)
                    .frame(width: 7, height: 7)
                Text(device.shortName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(device.os)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }

            if let m = metrics, !m.hasError {
                richBody(metrics: m)
            } else if device.hasGpu {
                fallbackGPULine()
            } else {
                Text(device.tailscaleIp.isEmpty ? device.os : device.tailscaleIp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            uptimeFooter()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(.quaternary, lineWidth: 1)
        )
        .opacity(device.isOnline ? 1 : 0.5)
    }

    @ViewBuilder
    private func uptimeFooter() -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let secs = metrics?.uptimeSeconds, secs > 0 {
                Text("up \(Self.formatUptime(seconds: secs))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("uptime —")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    static func formatUptime(seconds s: Int64) -> String {
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    @ViewBuilder
    private func richBody(metrics m: DeviceMetrics) -> some View {
        resourceRow(label: "CPU", value: m.cpu.usagePercent,
                    color: thresholdColor(m.cpu.usagePercent))
        resourceRow(label: "RAM", value: m.memory.usagePercent,
                    color: m.memory.usagePercent > 80 ? .red
                         : m.memory.usagePercent > 50 ? .orange : .blue)
        if device.hasGpu, let util = gpuUtil {
            resourceRow(label: "GPU", value: util, color: thresholdColor(util))
        }
    }

    private func resourceRow(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(color)
            Text("\(Int(value))%")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func thresholdColor(_ v: Double) -> Color {
        v > 80 ? .red : v > 50 ? .orange : .green
    }

    @ViewBuilder
    private func fallbackGPULine() -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gpu")
                .font(.caption2)
                .foregroundStyle(.purple)
            Text("\(device.gpuCount)x \(device.gpuModel ?? "GPU")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if let util = gpuUtil {
            HStack(spacing: 6) {
                ProgressView(value: min(max(util, 0), 100), total: 100)
                    .tint(util > 80 ? .red : util > 50 ? .orange : .green)
                Text("\(Int(util))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

// MARK: - GPU Section

private struct DashboardGPUSection: View {
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
                    HStack(spacing: 16) {
                        DashboardGaugeRing(
                            value: vm.avgGPUUtilization,
                            label: "Utilization",
                            color: gaugeColor(vm.avgGPUUtilization)
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            DashboardStatRow(label: "Avg Util", value: String(format: "%.0f%%", vm.avgGPUUtilization))
                            DashboardStatRow(label: "VRAM", value: String(format: "%.1f / %.1f GB", vm.totalVRAMUsedGB, vm.totalVRAMTotalGB))
                            DashboardStatRow(label: "GPUs", value: "\(vm.totalGPUs) across \(vm.gpuNodes.count) nodes")
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    ForEach(vm.gpuNodes) { node in
                        if let gpus = node.gpus, !gpus.isEmpty {
                            ForEach(gpus) { gpu in
                                HStack(spacing: 8) {
                                    Text(node.deviceName.components(separatedBy: ".").first ?? node.deviceName)
                                        .font(.caption)
                                        .frame(width: 70, alignment: .leading)
                                        .lineLimit(1)
                                    ProgressView(value: gpu.utilizationPercent, total: 100)
                                        .tint(gaugeColor(gpu.utilizationPercent))
                                    Text(String(format: "%.0f%%", gpu.utilizationPercent))
                                        .font(.system(.caption2, design: .monospaced))
                                        .frame(width: 30, alignment: .trailing)
                                    Text("\(gpu.temperatureC)°C")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(gpu.temperatureC > 80 ? .red : gpu.temperatureC > 60 ? .orange : .secondary)
                                        .frame(width: 34, alignment: .trailing)
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

private struct DashboardGaugeRing: View {
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
        .frame(width: 74, height: 74)
    }
}

private struct DashboardStatRow: View {
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

private struct DashboardRunningOrchsSection: View {
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

private struct DashboardRecentTasksSection: View {
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

private struct DashboardQuickCommandSection: View {
    @ObservedObject var vm: DashboardViewModel
    @AppStorage("aiExecPolicy") private var policyRaw = ExecPolicy.ask.rawValue
    private var policy: ExecPolicy { ExecPolicy(rawValue: policyRaw) ?? .ask }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
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
                    Spacer()
                }

                Picker("", selection: $policyRaw) {
                    ForEach(ExecPolicy.allCases) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    TextField("Command, or describe a goal for the AI agent…", text: $vm.quickCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    Button {
                        let t = vm.quickCommand
                        let did = vm.quickCommandDeviceId
                        vm.quickCommand = ""
                        Task { await vm.agentSubmit(text: t, deviceId: did, policy: policy) }
                    } label: {
                        Image(systemName: vm.agentBusy ? "hourglass" : "sparkles")
                    }
                    .disabled(vm.quickCommand.isEmpty || vm.agentBusy)

                    Button {
                        let t = vm.quickCommand
                        let did = vm.quickCommandDeviceId
                        vm.quickCommand = ""
                        Task { await vm.directSubmit(text: t, deviceId: did, policy: policy) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(vm.quickCommand.isEmpty || vm.quickCommandDeviceId == nil)
                }

                let entries = vm.activity.filter { $0.deviceId == vm.quickCommandDeviceId }
                if entries.isEmpty {
                    Text("No activity for this target yet — run a command (▶) or describe a goal for the agent (✨).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    HStack {
                        Text("Activity")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { vm.clearActivity(forDeviceId: vm.quickCommandDeviceId) }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        DashboardActivityRow(entry: entry, vm: vm)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
            }
        } label: {
            Label("Quick Command", systemImage: "terminal")
        }
    }
}

// MARK: - Activity row (unified: direct command + AI agent run)

private struct DashboardActivityRow: View {
    let entry: ActivityEntry
    @ObservedObject var vm: DashboardViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                statusIcon
                Image(systemName: entry.source == .ai ? "sparkles" : "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(.caption, design: entry.source == .user ? .monospaced : .default))
                    .lineLimit(2)
                Spacer()
                if let dev = entry.deviceName {
                    Text(dev).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button { vm.removeEntry(entry.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if let msg = entry.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }

            if entry.status == .pending {
                HStack {
                    if entry.source == .ai, let plan = entry.plan {
                        Text("Plan: \(plan.intent) · \(plan.actions.count) step(s)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Awaiting approval").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Deny") { vm.denyEntry(entry.id) }
                        .controlSize(.small)
                    Button {
                        Task { await vm.approve(entry.id) }
                    } label: {
                        Label(entry.source == .ai ? "Run" : "Approve", systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }

            if entry.status == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let results = entry.results, !results.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: r.status == "ok" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(r.status == "ok" ? .green : .red)
                                    Text("$ \(r.type)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                DashboardTerminalBlock(text: Self.resultText(r), isError: r.status != "ok")
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    let ok = results.filter { $0.status == "ok" }.count
                    Text("Terminal output · \(ok)/\(results.count) actions ok")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let out = entry.outputText, !out.isEmpty {
                DashboardTerminalBlock(text: out, isError: entry.status == .failed,
                                       lineLimit: expanded ? nil : 8)
                    .onTapGesture { expanded.toggle() }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusIcon: some View {
        switch entry.status {
        case .planning, .running:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "pause.circle").foregroundStyle(.blue)
        case .needsInput:
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
        case .denied:
            Image(systemName: "nosign").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    static func resultText(_ r: ActionResult) -> String {
        if let err = r.error, !err.isEmpty { return err }
        guard let out = r.output?.value else { return "(no output)" }
        switch out {
        case let s as String:   return s.isEmpty ? "(ok)" : s
        case is NSNull:         return "(ok)"
        default:                return String(describing: out)
        }
    }
}

// MARK: - Terminal-style output block

private struct DashboardTerminalBlock: View {
    @Environment(\.theme) private var theme
    let text: String
    var isError: Bool = false
    var lineLimit: Int? = nil

    var body: some View {
        Text(text.isEmpty ? "(no output)" : text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(isError ? Color(red: 1.0, green: 0.45, blue: 0.45)
                                     : Color(red: 0.55, green: 0.95, blue: 0.6))
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: theme.controlRadius))
    }
}
