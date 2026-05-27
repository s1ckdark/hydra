import Foundation

/// One Quick-Command agent run: a natural-language request taken through
/// the agent (plan → user-confirmed run → results). Kept in-memory for the
/// session and shown as a history list under the Quick Command card.
struct AgentRun: Identifiable {
    let id = UUID()
    let request: String
    let deviceName: String?
    var status: Status
    var planIntent: String?
    var plan: AgentPlan?
    var message: String?
    var results: [ActionResult]?
    let timestamp: Date

    enum Status {
        case planning      // waiting for the agent to return a plan/ask
        case awaitingRun   // plan ready, waiting for the user to click Run
        case needsInput    // agent asked a clarifying question
        case running       // executing the plan
        case done          // all actions ok
        case failed        // chat/execute error or an action failed
    }
}

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
    // AI agent runs (plan → confirmed run → results), newest first.
    @Published var agentHistory: [AgentRun] = []
    @Published var agentBusy = false

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

    /// Sends the Quick Command text to the agent as a natural-language goal.
    /// The agent replies with a plan (→ awaitingRun, the user clicks Run) or a
    /// clarifying question (→ needsInput). Each submit is independent (no
    /// carried conversation) and appears as a row in agentHistory.
    func agentSubmit() async {
        let nl = quickCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nl.isEmpty else { return }
        let device = quickCommandDeviceId.flatMap { id in devices.first { $0.id == id } }
        // Ground the agent on the selected target so execute_command actions
        // hit the right device; the agent's system prompt already lists ids.
        let message: String
        if let d = device {
            message = "[Target device: \(d.shortName) (id=\(d.id), os=\(d.os))]\n\(nl)"
        } else {
            message = nl
        }

        let run = AgentRun(request: nl, deviceName: device?.shortName,
                           status: .planning, planIntent: nil, plan: nil,
                           message: nil, results: nil, timestamp: Date())
        let runID = run.id
        agentHistory.insert(run, at: 0)
        agentBusy = true
        defer { agentBusy = false }

        do {
            let resp = try await api.chat(ChatRequest(history: [], message: message))
            if resp.type == "plan", let plan = resp.plan {
                updateRun(runID) {
                    $0.status = .awaitingRun
                    $0.plan = plan
                    $0.planIntent = plan.intent
                    $0.message = resp.message
                }
            } else {
                updateRun(runID) {
                    $0.status = .needsInput
                    $0.message = resp.message
                }
            }
            quickCommand = ""   // ready for the next request
        } catch {
            updateRun(runID) {
                $0.status = .failed
                $0.message = error.localizedDescription
            }
        }
    }

    /// Executes the plan attached to an awaitingRun history entry, then
    /// records the per-action results on that entry.
    func agentRun(_ runID: UUID) async {
        guard let plan = agentHistory.first(where: { $0.id == runID })?.plan else { return }
        updateRun(runID) { $0.status = .running }
        do {
            let resp = try await api.executePlan(plan)
            updateRun(runID) {
                $0.results = resp.results
                $0.status = resp.results.contains { $0.status != "ok" } ? .failed : .done
            }
        } catch {
            updateRun(runID) {
                $0.status = .failed
                $0.message = ($0.message.map { $0 + "\n" } ?? "") + "execute error: " + error.localizedDescription
            }
        }
    }

    /// Mutates the history entry with the given id in place. Re-finds the
    /// index each call so it stays correct across the await suspension points
    /// in agentSubmit / agentRun.
    private func updateRun(_ id: UUID, _ mutate: (inout AgentRun) -> Void) {
        guard let i = agentHistory.firstIndex(where: { $0.id == id }) else { return }
        mutate(&agentHistory[i])
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
