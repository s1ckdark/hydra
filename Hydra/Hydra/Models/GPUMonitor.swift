import Foundation

struct GPUMonitorResponse: Codable {
    let timestamp: Date
    let nodes: [GPUNodeStatus]
    let nodeCount: Int
}

struct GPUNodeStatus: Codable, Identifiable {
    let deviceId: String
    let deviceName: String
    let ip: String
    let gpuModel: String
    let gpuCount: Int
    let gpus: [GPUInfo]?
    let error: String?

    var id: String { deviceId }
    var hasError: Bool { error != nil && !error!.isEmpty }

    struct GPUInfo: Codable, Identifiable {
        let index: Int
        let name: String
        let utilizationPercent: Double
        let memoryUsedMB: Int
        let memoryTotalMB: Int
        let temperatureC: Int
        let powerDrawW: Double
        let powerLimitW: Double
        // Compute processes occupying this GPU; nil/empty when none are
        // running (or the driver doesn't report them).
        let processes: [GPUProcess]?
        // Extended nvidia-smi fields — optional so older servers that
        // omit them decode cleanly. 0/nil/"" all read as "unknown" in the UI.
        let clockSMMHz: Int?
        let clockMemoryMHz: Int?
        let fanSpeedPercent: Int?
        let pstate: String?
        let pcieLinkGen: Int?
        let pcieLinkWidth: Int?

        var id: Int { index }
        var memoryPercent: Double {
            guard memoryTotalMB > 0 else { return 0 }
            return Double(memoryUsedMB) / Double(memoryTotalMB) * 100
        }

        /// "1950 / 9501 MHz" or nil when neither clock is reported.
        var clocksText: String? {
            let sm = clockSMMHz ?? 0
            let mem = clockMemoryMHz ?? 0
            guard sm > 0 || mem > 0 else { return nil }
            return "\(sm) / \(mem) MHz"
        }

        /// "Gen 4 × 16" or nil when PCIe info is missing.
        var pcieText: String? {
            let g = pcieLinkGen ?? 0
            let w = pcieLinkWidth ?? 0
            guard g > 0, w > 0 else { return nil }
            return "Gen \(g) × \(w)"
        }
    }

    struct GPUProcess: Codable, Identifiable {
        let pid: Int
        let name: String
        let usedMemoryMB: Int

        var id: Int { pid }
        /// Human-readable VRAM (GB when ≥ 1 GiB, else MB).
        var vramText: String {
            usedMemoryMB >= 1024
                ? String(format: "%.1f GB", Double(usedMemoryMB) / 1024)
                : "\(usedMemoryMB) MB"
        }
    }
}
