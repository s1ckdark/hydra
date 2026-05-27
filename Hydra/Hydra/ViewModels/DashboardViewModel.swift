import Foundation

/// How AI-generated and direct commands are gated before execution, à la
/// Cursor/Windsurf: Allow (auto-run), Ask (approve each), Deny (block).
enum ExecPolicy: String, CaseIterable, Identifiable {
    case allow, ask, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .allow: return "Allow"
        case .ask:   return "Ask"
        case .auto:  return "Auto"
        }
    }
}

/// One entry in the Quick Command activity log — a direct command (▶) or an
/// AI agent run (✨), taken through the allow/ask/deny gate. In-memory for
/// the session, newest first.
struct ActivityEntry: Identifiable {
    let id = UUID()
    let source: Source
    let title: String          // NL goal (ai) or the literal command (user)
    let deviceName: String?
    let deviceId: String?      // for re-running a direct command on approve
    let command: String?       // user direct: the literal command
    var status: Status
    var planIntent: String?
    var plan: AgentPlan?       // ai: the plan to execute
    var message: String?
    var results: [ActionResult]?  // ai: per-action results
    var summary: String? = nil    // ai: natural-language result summary
    var outputText: String?       // user direct: command output
    let timestamp: Date

    enum Source { case user, ai }
    enum Status {
        case planning    // ai: waiting for a plan
        case needsInput  // ai: agent asked a clarifying question
        case pending     // waiting for approval (ask policy)
        case denied      // blocked by deny policy
        case running
        case done
        case failed
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
    @Published var agentBusy = false
    // Unified activity log: direct ▶ commands and ✨ AI runs, newest first.
    @Published var activity: [ActivityEntry] = []

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

    /// Runs the literal Quick Command on the selected device, gated by the
    /// allow/ask/deny policy. Logs to the activity list regardless of outcome.
    func directSubmit(text: String, deviceId: String?, policy: ExecPolicy) async {
        let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, let did = deviceId else { return }
        let device = devices.first { $0.id == did }
        let entry = ActivityEntry(source: .user, title: cmd, deviceName: device?.shortName,
                                  deviceId: did, command: cmd, status: .pending,
                                  planIntent: nil, plan: nil, message: nil,
                                  results: nil, outputText: nil, timestamp: Date())
        activity.insert(entry, at: 0)
        switch policy {
        case .allow:
            await runDirectCommand(entry.id)
        case .ask:
            break // stays .pending for Approve/Deny
        case .auto:
            await autoGateDirect(entry.id, command: cmd,
                                 os: device?.os ?? "", deviceName: device?.shortName ?? "")
        }
    }

    /// "Auto" gate for a direct command: the AI classifies safety. Safe
    /// commands run automatically; risky ones escalate to user approval with
    /// the AI's reason. A failed/unclear assessment also escalates.
    private func autoGateDirect(_ id: UUID, command: String, os: String, deviceName: String) async {
        update(id) { e in e.status = .running; e.message = "AI assessing safety…" }
        do {
            let verdict = try await api.assessCommand(command: command, os: os, deviceName: deviceName)
            if verdict.safe {
                update(id) { e in e.message = nil }
                await runDirectCommand(id)
            } else {
                update(id) { e in
                    e.status = .pending
                    e.message = "AI flagged as risky: \(verdict.reason ?? "review needed")"
                }
            }
        } catch {
            update(id) { e in
                e.status = .pending
                e.message = "AI safety check failed — approve manually. (\(error.localizedDescription))"
            }
        }
    }

    /// Sends the Quick Command text to the AI agent as a natural-language
    /// goal. The agent returns a plan (gated by policy) or a clarifying
    /// question. Each submit is independent and appears in the activity list.
    func agentSubmit(text: String, deviceId: String?, policy: ExecPolicy) async {
        let nl = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nl.isEmpty else { return }
        let device = deviceId.flatMap { id in devices.first { $0.id == id } }
        // Ground the agent on the selected target so execute_command actions
        // hit the right device; the agent's system prompt already lists ids.
        let message = device.map { "[Target device: \($0.shortName) (id=\($0.id), os=\($0.os))]\n\(nl)" } ?? nl

        let entry = ActivityEntry(source: .ai, title: nl, deviceName: device?.shortName,
                                  deviceId: deviceId, command: nil, status: .planning,
                                  planIntent: nil, plan: nil, message: nil,
                                  results: nil, outputText: nil, timestamp: Date())
        let id = entry.id
        activity.insert(entry, at: 0)
        agentBusy = true
        defer { agentBusy = false }

        do {
            let resp = try await api.chat(ChatRequest(history: [], message: message))
            if resp.type == "plan", let plan = resp.plan {
                update(id) { e in e.plan = plan; e.planIntent = plan.intent; e.message = resp.message }
                // For AI plans the planner already judges safety (it won't
                // propose destructive actions), so Allow and Auto both run;
                // Ask holds for approval.
                switch policy {
                case .allow, .auto: await runPlan(id)
                case .ask:          update(id) { e in e.status = .pending }
                }
            } else {
                update(id) { e in e.status = .needsInput; e.message = resp.message }
            }
        } catch {
            update(id) { e in e.status = .failed; e.message = error.localizedDescription }
        }
    }

    /// Approve a pending entry (ask policy) → execute it now.
    func approve(_ id: UUID) async {
        guard let e = activity.first(where: { $0.id == id }), e.status == .pending else { return }
        if e.source == .ai { await runPlan(id) } else { await runDirectCommand(id) }
    }

    /// Deny a pending entry — mark blocked, execute nothing.
    func denyEntry(_ id: UUID) {
        update(id) { e in if e.status == .pending { e.status = .denied } }
    }

    private func runPlan(_ id: UUID) async {
        guard let plan = activity.first(where: { $0.id == id })?.plan else { return }
        update(id) { e in e.status = .running }
        do {
            let resp = try await api.executePlan(plan)
            update(id) { e in
                e.results = resp.results
                e.summary = resp.summary
                e.status = resp.results.contains { $0.status != "ok" } ? .failed : .done
            }
        } catch {
            update(id) { e in
                e.status = .failed
                e.message = appendLine(e.message, "execute error: " + error.localizedDescription)
            }
        }
    }

    private func runDirectCommand(_ id: UUID) async {
        guard let entry = activity.first(where: { $0.id == id }),
              let did = entry.deviceId, let cmd = entry.command else { return }
        update(id) { e in e.status = .running }
        do {
            let r = try await api.executeOnDevice(id: did, command: cmd)
            update(id) { e in
                e.outputText = r.hasError ? (r.error ?? "") : r.output
                e.status = r.hasError ? .failed : .done
            }
        } catch {
            update(id) { e in e.outputText = error.localizedDescription; e.status = .failed }
        }
    }

    /// Removes a single activity entry (the row's ✕ button).
    func removeEntry(_ id: UUID) {
        activity.removeAll { $0.id == id }
    }

    /// Clears all activity for one device (nil = the no-target bucket).
    func clearActivity(forDeviceId deviceId: String?) {
        activity.removeAll { $0.deviceId == deviceId }
    }

    /// Mutates the activity entry with the given id in place, re-finding the
    /// index each call so it stays correct across await suspension points.
    private func update(_ id: UUID, _ mutate: (inout ActivityEntry) -> Void) {
        guard let i = activity.firstIndex(where: { $0.id == id }) else { return }
        mutate(&activity[i])
    }

    private func appendLine(_ existing: String?, _ line: String) -> String {
        guard let m = existing, !m.isEmpty else { return line }
        return m + "\n" + line
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
