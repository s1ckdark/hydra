import Foundation

@MainActor
class GPUMonitorViewModel: ObservableObject {
    @Published var nodes: [GPUNodeStatus] = []
    @Published var isLoading = false
    @Published var lastUpdate: Date?
    @Published var error: String?
    /// deviceId -> when we last saw fresh GPU numbers for it. Present only
    /// for nodes whose *current* response was empty/errored and we patched
    /// in cached data; the menu bar consults this to render "Xm ago".
    @Published var staleSince: [String: Date] = [:]

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var lastGood: [String: (gpus: [GPUNodeStatus.GPUInfo], at: Date)] = [:]

    var totalGPUs: Int { nodes.reduce(0) { $0 + ($1.gpus?.count ?? 0) } }
    var avgUtilization: Double {
        let allGPUs = nodes.flatMap { $0.gpus ?? [] }
        guard !allGPUs.isEmpty else { return 0 }
        return allGPUs.reduce(0) { $0 + $1.utilizationPercent } / Double(allGPUs.count)
    }
    var avgTemperature: Int {
        let allGPUs = nodes.flatMap { $0.gpus ?? [] }
        guard !allGPUs.isEmpty else { return 0 }
        return allGPUs.reduce(0) { $0 + $1.temperatureC } / allGPUs.count
    }
    var summaryText: String {
        guard !nodes.isEmpty else { return "No GPU data" }
        return String(format: "%.0f%% · %d°C · %d GPUs", avgUtilization, avgTemperature, totalGPUs)
    }

    func startPolling(interval: TimeInterval = 5) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        isLoading = true
        do {
            let response = try await api.getGPUMonitor()
            let now = Date()
            var newStale: [String: Date] = [:]
            nodes = response.nodes.map { node in
                if let gpus = node.gpus, !gpus.isEmpty {
                    lastGood[node.deviceId] = (gpus, now)
                    return node
                }
                if let cached = lastGood[node.deviceId] {
                    newStale[node.deviceId] = cached.at
                    return GPUNodeStatus(
                        deviceId: node.deviceId,
                        deviceName: node.deviceName,
                        ip: node.ip,
                        gpuModel: node.gpuModel,
                        gpuCount: cached.gpus.count,
                        gpus: cached.gpus,
                        error: node.error
                    )
                }
                return node
            }
            staleSince = newStale
            lastUpdate = response.timestamp
            error = nil
        } catch {
            self.error = error.localizedDescription
            // Keep nodes / staleSince as-is so the menu bar keeps showing
            // the last picture we had instead of going blank.
        }
        isLoading = false
    }
}
