import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var appState: AppState

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

                // At-a-glance device cards (online first). Tap to jump to the
                // device's detail in the Devices tab.
                DevicesOverviewSection(vm: vm)

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
        // Initial-load spinner: only while loading AND we have nothing to
        // show yet, so polling refreshes (data already present) don't cover
        // the dashboard. I/O-bound first loads now read as "loading", not
        // "empty".
        .overlay {
            if vm.isLoading && vm.devices.isEmpty && vm.orchs.isEmpty {
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
        .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
        .toolbar {
            ToolbarItem {
                // Spinner while any load is in flight; the refresh button
                // otherwise. Gives feedback during the slow force-refresh
                // (re-probes every device over SSH).
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { Task { await vm.load(force: true) } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Force refresh — re-probe and re-collect metrics from every device")
                }
            }
        }
        .navigationTitle("Dashboard")
        .onAppear { vm.startPolling(interval: 15) }
        .onDisappear { vm.stopPolling() }
    }
}

// MARK: - Server Status Banner

struct ServerStatusBanner: View {
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

struct OfflineAlert: View {
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
    @AppStorage("aiExecPolicy") private var policyRaw = ExecPolicy.ask.rawValue
    private var policy: ExecPolicy { ExecPolicy(rawValue: policyRaw) ?? .ask }

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

                    Spacer()

                    // Execution policy (Cursor/Windsurf style) — gates BOTH
                    // ✨ AI plans and ▶ direct commands.
                    Picker("", selection: $policyRaw) {
                        ForEach(ExecPolicy.allCases) { p in
                            Text(p.label).tag(p.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Allow = run all · Ask = approve each · Auto = AI runs safe ones, asks on risky")
                }

                // Command input
                HStack {
                    TextField("Command, or describe a goal for the AI agent…", text: $vm.quickCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    // ✨ Agent: NL goal → plan, gated by the policy.
                    Button {
                        let t = vm.quickCommand
                        let did = vm.quickCommandDeviceId
                        vm.quickCommand = ""
                        Task { await vm.agentSubmit(text: t, deviceId: did, policy: policy) }
                    } label: {
                        Image(systemName: vm.agentBusy ? "hourglass" : "sparkles")
                    }
                    .help("Ask the AI agent to plan & run this")
                    .disabled(vm.quickCommand.isEmpty || vm.agentBusy)

                    // ▶ direct command on the target, gated by the policy.
                    Button {
                        let t = vm.quickCommand
                        let did = vm.quickCommandDeviceId
                        vm.quickCommand = ""
                        Task { await vm.directSubmit(text: t, deviceId: did, policy: policy) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Run this command directly on the selected device")
                    .disabled(vm.quickCommand.isEmpty || vm.quickCommandDeviceId == nil)
                }

                // Activity log — kept per device; shows the selected target's
                // history (direct ▶ and ✨ AI runs), newest first.
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
                        ActivityRow(entry: entry, vm: vm)
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

/// Shared by the dashboard Quick Command and the device detail view.
struct ActivityRow: View {
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
                .help("Remove from history")
            }

            if let msg = entry.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }

            // Pending approval (Ask policy): Approve / Deny.
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

            // AI: natural-language summary — the agent explains what it did
            // and found, above the raw terminal output.
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // AI per-action results rendered as terminal output, collapsed.
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
                                TerminalBlock(text: Self.resultText(r), isError: r.status != "ok")
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

            // Direct command output as terminal text.
            if let out = entry.outputText, !out.isEmpty {
                TerminalBlock(text: out, isError: entry.status == .failed,
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

    /// Human-readable one-liner for an action result: its error, or its
    /// output rendered from the AnyCodable payload.
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

/// Monospace command/action output on a dark background — light green for
/// normal output, red for errors — so AI/agent results read like a terminal.
struct TerminalBlock: View {
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
        .cardStyle()
    }
}

// MARK: - Devices overview (compact cards)

/// Compact, at-a-glance device cards for the dashboard: status, OS, and GPU
/// load (or IP). Online devices come first; tapping a card opens that device
/// in the Devices tab. Reuses the dashboard's existing device + GPU data —
/// no extra API calls.
struct DevicesOverviewSection: View {
    @ObservedObject var vm: DashboardViewModel
    @EnvironmentObject var appState: AppState

    /// Average live GPU utilization per device, from the monitor data.
    private var utilByDevice: [String: Double] {
        var map: [String: Double] = [:]
        for node in vm.gpuNodes {
            guard let gpus = node.gpus, !gpus.isEmpty else { continue }
            map[node.deviceId] = gpus.reduce(0) { $0 + $1.utilizationPercent } / Double(gpus.count)
        }
        return map
    }

    /// Online devices first, then alphabetical by short name.
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(sortedDevices) { device in
                        DashboardDeviceCard(
                            device: device,
                            gpuUtil: utilByDevice[device.id],
                            metrics: vm.metricsByDevice[device.id]
                        )
                        .onTapGesture {
                            appState.selectedDeviceId = device.id
                            appState.activeTab = .devices
                        }
                    }
                }
            }
        } label: {
            Label("Devices", systemImage: "desktopcomputer")
        }
    }
}

/// Rich device card. Header is fixed (status dot + name + OS); the body shows
/// live CPU/RAM/GPU resource bars when metrics are available, and falls back
/// to a single info line (GPU model or Tailscale IP) when they aren't yet.
struct DashboardDeviceCard: View {
    @Environment(\.theme) private var theme
    let device: Device
    let gpuUtil: Double?
    let metrics: DeviceMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header — kept identical across density modes so the card's
            // "at a glance" signal (status + name + OS) doesn't shift.
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

            // Rich body — show CPU/RAM/GPU resource bars when we have a
            // metrics snapshot for this device. Before the first poll lands
            // (or for devices whose SSH probe is failing), keep the older
            // single-line summary so the card never collapses.
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

            // Footer row — uptime when known, pushed to the bottom by the
            // Spacer above it so every card's footer aligns at the same
            // vertical position regardless of body density.
            Spacer(minLength: 0)
            uptimeFooter()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(.quaternary, lineWidth: 1)
        )
        .opacity(device.isOnline ? 1 : 0.5)
        .contentShape(Rectangle())
        .help(device.isOnline ? "Open \(device.shortName)" : "\(device.shortName) — offline")
    }

    /// One-line footer with the host's uptime. Shown only when the metrics
    /// snapshot carries a value; otherwise an empty placeholder keeps the
    /// card's vertical rhythm consistent across cards.
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

    /// "12d 5h" / "5h 23m" / "23m" — coarsest two units, so the footer fits
    /// in the narrowest card width without truncating.
    static func formatUptime(seconds s: Int64) -> String {
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    /// Resource bars (CPU + RAM, plus GPU when present). Three rows of the
    /// same shape — short label, bar, %. Mirrors the thresholds used in
    /// DeviceDetailView so a glance at the dashboard reads the same as the
    /// detail page (>80 red, >50 orange, else green; RAM uses blue as its
    /// nominal tint to stay visually distinct from CPU/GPU load).
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

    /// One resource row: short label, capped 0–100 progress bar, monospaced %.
    /// Label/value columns are fixed so all three rows align under any locale.
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

    /// Shared CPU/GPU load threshold — matches DeviceDetailView so the
    /// dashboard's color cue is the same one the detail page uses.
    private func thresholdColor(_ v: Double) -> Color {
        v > 80 ? .red : v > 50 ? .orange : .green
    }

    /// Pre-metrics fallback for GPU nodes: model + util bar so the card has
    /// a useful first frame before the snapshot lands.
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
