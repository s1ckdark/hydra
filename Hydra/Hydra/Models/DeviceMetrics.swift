import Foundation

struct DeviceMetrics: Codable {
    let deviceId: String
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let disk: DiskMetrics
    /// Host uptime in seconds since boot. Optional — older servers and
    /// self-reporting agents that haven't been updated yet omit it.
    let uptimeSeconds: Int64?
    let collectedAt: Date
    let error: String?
    /// True when `error` is the connection circuit breaker declining to dial
    /// (too many recent failures) rather than a live dial that failed. Drives
    /// the "cooling down / retry pending" UI and the manual retry affordance.
    /// Optional — older servers omit it.
    let suppressed: Bool?

    var hasError: Bool { error != nil && !error!.isEmpty }

    /// The device is in the breaker's cooling-down state: reachable attempts
    /// are being suppressed on purpose, distinct from an outright failure.
    var isSuppressed: Bool { suppressed == true }

    struct CPUMetrics: Codable {
        let usagePercent: Double
        let cores: Int
        let modelName: String
        let loadAvg1: Double
        let loadAvg5: Double
        let loadAvg15: Double
    }

    struct MemoryMetrics: Codable {
        let total: UInt64
        let used: UInt64
        let free: UInt64
        let available: UInt64
        let usagePercent: Double
        let swapTotal: UInt64
        let swapUsed: UInt64
        let swapFree: UInt64

        var totalGB: String { formatBytes(total) }
        var usedGB: String { formatBytes(used) }
        var availableGB: String { formatBytes(available) }

        private func formatBytes(_ bytes: UInt64) -> String {
            let gb = Double(bytes) / 1_073_741_824
            return String(format: "%.1fG", gb)
        }
    }

    struct DiskMetrics: Codable {
        let partitions: [Partition]?

        struct Partition: Codable, Identifiable {
            let mountPoint: String
            let device: String
            let total: UInt64
            let used: UInt64
            let free: UInt64
            let usagePercent: Double

            var id: String { mountPoint }
            var totalGB: String { String(format: "%.0fG", Double(total) / 1_073_741_824) }
            var usedGB: String { String(format: "%.0fG", Double(used) / 1_073_741_824) }
        }
    }
}
