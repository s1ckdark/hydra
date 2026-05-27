import Foundation

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var orchs: [Orch] = []
    @Published var gpuNodes: [GPUNodeStatus] = []
    @Published var tasks: [NagaTask] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var serverStatus: ServerStatus = .unknown
    @Published var serverVersion: String = ""
    @Published var lastRefresh: Date?

    // Quick command
    @Published var quickCommand = ""
    @Published var quickCommandDeviceId: String?
    @Published var quickCommandResult: TaskResult?
    @Published var isExecutingQuickCommand = false
    // AI command assistant (natural-language → shell command)
    @Published var isGeneratingCommand = false
    @Published var commandGenError: String?

    // Per-device ping cache. Lives on the shared ViewModel (not in
    // DeviceDetailView's @State) so switching the selected device does not
    // leak the previous device's chart into the new one — the detail view
    // simply reads `pingResults[device.id]` and re-renders cleanly.
    @Published var pingResults: [String: PingResult] = [:]
    @Published var pingErrors: [String: String] = [:]
    @Published var pingingDeviceIds: Set<String> = []

    enum ServerStatus: String {
        case connected, disconnected, unknown
    }

    /// Combined health used by the top banner.
    /// - healthy:  server reachable AND all devices online
    /// - degraded: server reachable BUT one or more devices offline
    /// - down:     server unreachable (device status unknown)
    /// - unknown:  still checking
    enum SystemHealth {
        case healthy, degraded, down, unknown
    }

    var gpuDevices: [Device] { devices.filter { $0.hasGpu } }
    var onlineDevices: [Device] { devices.filter { $0.isOnline } }
    var offlineDevices: [Device] { devices.filter { !$0.isOnline } }
    var totalGPUs: Int { gpuDevices.reduce(0) { $0 + $1.gpuCount } }

    var systemHealth: SystemHealth {
        switch serverStatus {
        case .unknown: return .unknown
        case .disconnected: return .down
        case .connected: return offlineDevices.isEmpty ? .healthy : .degraded
        }
    }

    // GPU aggregate stats
    var avgGPUUtilization: Double {
        let allGPUs = gpuNodes.flatMap { $0.gpus ?? [] }
        guard !allGPUs.isEmpty else { return 0 }
        return allGPUs.reduce(0) { $0 + $1.utilizationPercent } / Double(allGPUs.count)
    }
    var totalVRAMUsedGB: Double {
        Double(gpuNodes.flatMap { $0.gpus ?? [] }.reduce(0) { $0 + $1.memoryUsedMB }) / 1024
    }
    var totalVRAMTotalGB: Double {
        Double(gpuNodes.flatMap { $0.gpus ?? [] }.reduce(0) { $0 + $1.memoryTotalMB }) / 1024
    }

    // Task stats
    var runningTasks: [NagaTask] { tasks.filter { $0.isRunning } }
    var recentTasks: [NagaTask] {
        tasks.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
            .prefix(10)
            .map { $0 }
    }
    var runningOrchs: [Orch] { orchs.filter { $0.isRunning } }

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?

    /// Loads the current dashboard state. Pass `force: true` for a user-
    /// initiated refresh — the server then bypasses its Tailscale cache,
    /// re-probes :22 on every device, and re-collects SSH metrics before
    /// responding. The default `false` is used by the background poller
    /// so the lighter cached path runs every tick.
    func load(force: Bool = false) async {
        isLoading = true
        error = nil
        await checkServerHealth()
        do {
            // Mobile devices visible by default (iPhone / iPad act as
            // orchestration controllers). The toggle on the device list
            // view is now an opt-OUT — when the user wants a worker-only
            // view, hideMobileDevices flips to true and we pass
            // include_mobile=false to the server.
            let hideMobile = UserDefaults.standard.bool(forKey: "hideMobileDevices")
            async let d = api.listDevices(refresh: force, includeMobile: !hideMobile)
            async let c = api.listOrchs()
            devices = try await d
            orchs = try await c
        } catch {
            self.error = error.localizedDescription
        }
        // Non-blocking secondary fetches
        await loadGPU()
        await loadTasks()
        lastRefresh = Date()
        isLoading = false
    }

    func startPolling(interval: TimeInterval = 10) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Probes the device's :22 reachability and caches the result by
    /// `deviceId`. The detail view reads the cache, so switching devices
    /// preserves each device's last measurement instead of showing the
    /// previously-selected device's chart.
    func runPing(deviceId: String, count: Int = 5) async {
        pingingDeviceIds.insert(deviceId)
        pingErrors[deviceId] = nil
        defer { pingingDeviceIds.remove(deviceId) }
        do {
            let result = try await api.pingDevice(id: deviceId, count: count)
            pingResults[deviceId] = result
        } catch {
            pingResults[deviceId] = nil
            pingErrors[deviceId] = error.localizedDescription
        }
    }

    func executeQuickCommand() async {
        guard !quickCommand.isEmpty, let deviceId = quickCommandDeviceId else { return }
        isExecutingQuickCommand = true
        do {
            quickCommandResult = try await api.executeOnDevice(id: deviceId, command: quickCommand)
        } catch {
            quickCommandResult = TaskResult(
                deviceId: deviceId, deviceName: "", gpu: "",
                output: "", error: error.localizedDescription, durationMs: 0
            )
        }
        isExecutingQuickCommand = false
    }

    /// Asks the AI to turn the natural-language text currently in
    /// `quickCommand` into a shell command, scoped to the selected device's
    /// OS, and replaces the field with the result for the user to review
    /// before running. Refusals/errors surface via `commandGenError`.
    func generateQuickCommand() async {
        let prompt = quickCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isGeneratingCommand = true
        commandGenError = nil
        defer { isGeneratingCommand = false }
        let device = quickCommandDeviceId.flatMap { id in devices.first { $0.id == id } }
        do {
            let resp = try await api.generateCommand(
                prompt: prompt,
                os: device?.os ?? "",
                deviceName: device?.shortName ?? ""
            )
            if resp.refused {
                commandGenError = "AI declined: \(resp.reason ?? "unsafe request")"
            } else if resp.command.isEmpty {
                commandGenError = "AI returned an empty command."
            } else {
                quickCommand = resp.command
            }
        } catch {
            commandGenError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func checkServerHealth() async {
        do {
            let health = try await api.healthCheck()
            serverStatus = health.status == "healthy" ? .connected : .disconnected
            serverVersion = health.version
        } catch {
            serverStatus = .disconnected
            serverVersion = ""
        }
    }

    private func loadGPU() async {
        do {
            let response = try await api.getGPUMonitor()
            gpuNodes = response.nodes
        } catch {
            // GPU monitoring is optional
        }
    }

    private func loadTasks() async {
        do {
            tasks = try await api.listTasks()
        } catch {
            // Task list is optional
        }
    }
}
