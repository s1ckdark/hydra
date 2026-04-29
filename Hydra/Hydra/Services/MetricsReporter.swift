import Foundation
import Darwin

/// Periodically samples local CPU/memory/disk/GPU and POSTs the snapshot
/// to /api/devices/{id}/metrics so the dashboard panels for the GUI
/// host fill in. Bypasses the SSH metrics path that would otherwise
/// require the server to ssh-into-self.
@MainActor
final class MetricsReporter {
    static let shared = MetricsReporter()
    private var task: Task<Void, Never>?
    private var prevCPU: host_cpu_load_info?

    /// Starts the 5-second reporting loop. Idempotent — calling start()
    /// twice cancels the previous loop first.
    func start(via client: APIClient) {
        task?.cancel()
        prevCPU = nil
        task = Task.detached { [weak self] in
            guard let self else { return }
            // Seed prevCPU so the first reported sample isn't a 0%
            // misread. The seed itself is discarded.
            await self.seedCPU()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self.tick(via: client)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func seedCPU() async {
        var seed: host_cpu_load_info? = nil
        _ = MetricsSampler.sampleCPU(prev: &seed)
        await MainActor.run { self.prevCPU = seed }
    }

    private func tick(via client: APIClient) async {
        guard let id = await DeviceIdentity.shared.current(via: client) else {
            // Identity not yet resolved — try again next tick. No log
            // spam: DeviceIdentity already logs once on each failure.
            return
        }

        let cpu = await MainActor.run { () -> CPUSnapshot in
            return MetricsSampler.sampleCPU(prev: &self.prevCPU)
        }
        let memory = MetricsSampler.sampleMemory()
        let disk = MetricsSampler.sampleDisk()
        let gpu = MetricsSampler.sampleGPU()

        let payload = DeviceMetricsPayload(
            cpu: .init(
                usagePercent: cpu.usagePercent,
                cores: cpu.cores,
                loadAvg1: cpu.loadAvg1,
                loadAvg5: cpu.loadAvg5,
                loadAvg15: cpu.loadAvg15
            ),
            memory: .init(
                total: memory.totalBytes,
                used: memory.usedBytes,
                free: memory.freeBytes,
                available: memory.availableBytes,
                usagePercent: memory.usagePercent
            ),
            disk: .init(partitions: [
                .init(
                    mountPoint: "/",
                    device: "",
                    fsType: "",
                    total: disk.totalBytes,
                    used: disk.totalBytes >= disk.availableBytes ? disk.totalBytes - disk.availableBytes : 0,
                    free: disk.availableBytes,
                    usagePercent: disk.usagePercent
                )
            ]),
            gpu: gpu.map { snap in
                DeviceMetricsPayload.GPUPayload(gpus: [
                    .init(
                        index: 0,
                        name: snap.name,
                        memoryTotal: snap.recommendedWorkingSetBytes,
                        memoryUsed: 0,
                        memoryFree: snap.recommendedWorkingSetBytes,
                        usagePercent: 0,
                        temperature: 0,
                        powerDraw: 0,
                        powerLimit: 0
                    )
                ])
            }
        )

        do {
            try await client.postMetrics(deviceID: id, payload: payload)
        } catch {
            // Best-effort. Server unreachable / transient errors fall
            // through to the next tick.
            NSLog("[MetricsReporter] postMetrics failed: %@", "\(error)")
        }
    }
}
