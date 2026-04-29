import Foundation
import Darwin
#if os(macOS)
import Metal
#endif

struct CPUSnapshot {
    let usagePercent: Double
    let cores: Int
    let loadAvg1: Double
    let loadAvg5: Double
    let loadAvg15: Double
}

struct MemorySnapshot {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let usagePercent: Double
}

struct DiskSnapshot {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let usagePercent: Double
}

struct GPUSnapshot {
    let name: String
    let recommendedWorkingSetBytes: UInt64
    let isLowPower: Bool
}

/// Pure-function metric samplers. No state — `sampleCPU` requires the
/// caller to hold the previous tick snapshot for delta computation.
enum MetricsSampler {

    static func sampleCPU(prev: inout host_cpu_load_info?) -> CPUSnapshot {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kern == KERN_SUCCESS else {
            return CPUSnapshot(usagePercent: 0,
                               cores: ProcessInfo.processInfo.processorCount,
                               loadAvg1: 0, loadAvg5: 0, loadAvg15: 0)
        }

        // Compute delta against prev. First call has no prev → 0%.
        var usage = 0.0
        if let p = prev {
            let userDelta = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
            let sysDelta  = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
            let idleDelta = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
            let niceDelta = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
            let total = userDelta + sysDelta + idleDelta + niceDelta
            if total > 0 {
                usage = (userDelta + sysDelta + niceDelta) / total * 100.0
            }
        }
        prev = info

        var loadInfo = [Double](repeating: 0, count: 3)
        getloadavg(&loadInfo, 3)

        return CPUSnapshot(
            usagePercent: usage,
            cores: ProcessInfo.processInfo.processorCount,
            loadAvg1: loadInfo[0],
            loadAvg5: loadInfo[1],
            loadAvg15: loadInfo[2]
        )
    }

    static func sampleMemory() -> MemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory  // bytes

        var info = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kern == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: total, usedBytes: 0, freeBytes: total, usagePercent: 0)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(info.free_count) * pageSize
        let active = UInt64(info.active_count) * pageSize
        let inactive = UInt64(info.inactive_count) * pageSize
        let wired = UInt64(info.wire_count) * pageSize
        let compressed = UInt64(info.compressor_page_count) * pageSize
        let used = active + inactive + wired + compressed
        let percent = total > 0 ? Double(used) / Double(total) * 100.0 : 0
        return MemorySnapshot(totalBytes: total, usedBytes: used, freeBytes: free, usagePercent: percent)
    }

    static func sampleDisk() -> DiskSnapshot {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let avail = values.volumeAvailableCapacityForImportantUsage else {
            return DiskSnapshot(totalBytes: 0, availableBytes: 0, usagePercent: 0)
        }
        let used = UInt64(total) - UInt64(avail)
        let percent = total > 0 ? Double(used) / Double(total) * 100.0 : 0
        return DiskSnapshot(totalBytes: UInt64(total), availableBytes: UInt64(avail), usagePercent: percent)
    }

    #if os(macOS)
    static func sampleGPU() -> GPUSnapshot? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return GPUSnapshot(
            name: device.name,
            recommendedWorkingSetBytes: UInt64(device.recommendedMaxWorkingSetSize),
            isLowPower: device.isLowPower
        )
    }
    #else
    static func sampleGPU() -> GPUSnapshot? { nil }
    #endif
}
