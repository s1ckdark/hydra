package com.hydra.android.core.data

import com.hydra.android.core.model.Device
import com.hydra.android.core.model.DeviceMetrics
import com.hydra.android.core.model.GpuNodeStatus
import com.hydra.android.core.model.NagaTask
import com.hydra.android.core.model.Orch

enum class ServerStatus { CONNECTED, DISCONNECTED, UNKNOWN }

/**
 * Combined health used by the top banner, mirroring iOS SystemHealth:
 * healthy = server reachable AND every device online; degraded = server
 * reachable but something is offline; down = server unreachable.
 */
enum class SystemHealth { HEALTHY, DEGRADED, DOWN, UNKNOWN }

data class DashboardSnapshot(
    val serverStatus: ServerStatus = ServerStatus.UNKNOWN,
    val serverVersion: String = "",
    val devices: List<Device> = emptyList(),
    val orchs: List<Orch> = emptyList(),
    val tasks: List<NagaTask> = emptyList(),
    val gpuNodes: List<GpuNodeStatus> = emptyList(),
    val metricsByDevice: Map<String, DeviceMetrics> = emptyMap(),
    val error: String? = null,
) {
    val onlineDevices: List<Device> get() = devices.filter { it.isOnline }
    val offlineDevices: List<Device> get() = devices.filter { !it.isOnline }
    val gpuDevices: List<Device> get() = devices.filter { it.hasGpu }
    val totalGpus: Int get() = gpuDevices.sumOf { it.gpuCount }
    val runningOrchs: List<Orch> get() = orchs.filter { it.isRunning }
    val runningTasks: List<NagaTask> get() = tasks.filter { it.isRunning }

    val recentTasks: List<NagaTask>
        get() = tasks.sortedByDescending { it.sortInstant }.take(10)

    private val allGpus get() = gpuNodes.flatMap { it.gpus.orEmpty() }

    val avgGpuUtilization: Double
        get() = allGpus.takeIf { it.isNotEmpty() }
            ?.let { gpus -> gpus.sumOf { it.utilizationPercent } / gpus.size }
            ?: 0.0

    val totalVramUsedGb: Double get() = allGpus.sumOf { it.memoryUsedMB }.toDouble() / 1024
    val totalVramTotalGb: Double get() = allGpus.sumOf { it.memoryTotalMB }.toDouble() / 1024

    val systemHealth: SystemHealth
        get() = when (serverStatus) {
            ServerStatus.UNKNOWN -> SystemHealth.UNKNOWN
            ServerStatus.DISCONNECTED -> SystemHealth.DOWN
            ServerStatus.CONNECTED ->
                if (offlineDevices.isEmpty()) SystemHealth.HEALTHY else SystemHealth.DEGRADED
        }
}
