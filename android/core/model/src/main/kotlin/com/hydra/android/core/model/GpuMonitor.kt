package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class GpuMonitorResponse(
    @Serializable(with = InstantSerializer::class) val timestamp: Instant,
    val nodes: List<GpuNodeStatus> = emptyList(),
    val nodeCount: Int = 0,
)

@Serializable
data class GpuNodeStatus(
    val deviceId: String,
    val deviceName: String = "",
    val ip: String = "",
    val gpuModel: String = "",
    val gpuCount: Int = 0,
    val gpus: List<GpuInfo>? = null,
    val error: String? = null,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
}

/**
 * The extended nvidia-smi fields are nullable so older servers that omit them
 * still decode; 0/null/"" all read as "unknown" in the UI.
 */
@Serializable
data class GpuInfo(
    val index: Int,
    val name: String = "",
    val utilizationPercent: Double = 0.0,
    val memoryUsedMB: Int = 0,
    val memoryTotalMB: Int = 0,
    val temperatureC: Int = 0,
    val powerDrawW: Double = 0.0,
    val powerLimitW: Double = 0.0,
    val processes: List<GpuProcess>? = null,
    val clockSMMHz: Int? = null,
    val clockMemoryMHz: Int? = null,
    val fanSpeedPercent: Int? = null,
    val pstate: String? = null,
    val pcieLinkGen: Int? = null,
    val pcieLinkWidth: Int? = null,
) {
    val memoryPercent: Double
        get() = if (memoryTotalMB > 0) memoryUsedMB.toDouble() / memoryTotalMB * 100 else 0.0
}

@Serializable
data class GpuProcess(val pid: Int, val name: String = "", val usedMemoryMB: Int = 0)
