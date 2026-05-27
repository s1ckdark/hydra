import Foundation

/// Composes the per-request context preamble that prepends every chat
/// message. The server treats the preamble as part of the user message
/// — no server-side change required.
@MainActor
enum ChatContextProvider {

    struct Selection {
        var device: Device?
        var orch: Orch?
        var task: SavedTask?
    }

    static func snapshot(
        for tab: AppState.Tab,
        dashboardVM: DashboardViewModel,
        selection: Selection
    ) -> String? {
        let body: String
        switch tab {
        case .settings:
            return nil
        case .dashboard:
            body = dashboardBody(dashboardVM)
        case .devices:
            body = devicesBody(dashboardVM, selected: selection.device)
        case .orchs:
            body = orchsBody(dashboardVM, selected: selection.orch)
        case .tasks:
            body = tasksBody(dashboardVM, selected: selection.task)
        }
        return "[Context: \(body)]"
    }

    // MARK: - Per-tab composers

    private static func dashboardBody(_ vm: DashboardViewModel) -> String {
        var parts: [String] = ["Dashboard."]
        let statusWord: String = {
            switch vm.serverStatus {
            case .connected: return "connected"
            case .disconnected: return "disconnected"
            case .unknown: return "unknown"
            }
        }()
        if !vm.serverVersion.isEmpty {
            parts.append("Server v\(vm.serverVersion) \(statusWord).")
        } else {
            parts.append("Server \(statusWord).")
        }
        parts.append("Devices \(vm.onlineDevices.count)/\(vm.devices.count) online.")
        if !vm.offlineDevices.isEmpty {
            let names = vm.offlineDevices.prefix(3).map(\.shortName).joined(separator: ", ")
            parts.append("Offline: \(names).")
        }
        if !vm.runningOrchs.isEmpty {
            let names = vm.runningOrchs.prefix(3).map(\.name).joined(separator: ", ")
            parts.append("Orchs running: \(names).")
        }
        if vm.totalGPUs > 0 {
            parts.append("\(vm.totalGPUs) GPUs avg \(Int(vm.avgGPUUtilization))% util.")
        }
        if !vm.tasks.isEmpty {
            parts.append("Tasks: \(vm.runningTasks.count) running, \(vm.tasks.count) total.")
        }
        return parts.joined(separator: " ")
    }

    private static func devicesBody(_ vm: DashboardViewModel, selected: Device?) -> String {
        guard let d = selected else {
            return "Devices tab. \(vm.onlineDevices.count)/\(vm.devices.count) devices online."
        }
        var attrs: [String] = [d.tailscaleIp, d.os]
        if d.hasGpu, let model = d.gpuModel {
            attrs.append("\(d.gpuCount)× \(model)")
        }
        attrs.append(d.isOnline ? "online" : "offline")
        attrs.append("SSH \(d.sshEnabled ? "on" : "off")")
        return "Devices tab. Selected '\(d.shortName)' (\(attrs.joined(separator: ", "))). \(vm.devices.count - 1) other devices visible."
    }

    private static func orchsBody(_ vm: DashboardViewModel, selected: Orch?) -> String {
        guard let o = selected else {
            return "Orchs tab. \(vm.runningOrchs.count) of \(vm.orchs.count) running."
        }
        let head = vm.devices.first { $0.id == o.coordinatorId }?.shortName ?? String(o.coordinatorId.prefix(8))
        let status = o.isRunning ? "running" : "stopped"
        return "Orchs tab. Selected '\(o.name)' (\(status), mode=\(o.mode), head=\(head), \(o.workerCount) workers)."
    }

    private static func tasksBody(_ vm: DashboardViewModel, selected: SavedTask?) -> String {
        let store = SavedTaskStore.shared
        let savedCount = store.tasks.count
        let runningCount = store.runningTaskIds.count
        guard let t = selected else {
            return "Tasks tab. \(savedCount) saved tasks, \(runningCount) running."
        }
        let cmdPreview = t.command.prefix(60)
        // SavedTask carries a single optional targetDeviceId (nil = ask at
        // runtime), not a list — resolve it to a readable short name.
        let target: String = {
            guard let id = t.targetDeviceId else { return "no target (asks at runtime)" }
            let name = vm.devices.first { $0.id == id }?.shortName ?? t.targetDeviceName ?? id
            return "target: \(name)"
        }()
        return "Tasks tab. Selected '\(t.name)' (\(target)). Command: \(cmdPreview)."
    }
}
