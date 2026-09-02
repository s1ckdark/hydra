package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

/**
 * Byte counts are UInt64 on the Swift side; real values sit far below
 * Long.MAX_VALUE, so Long is the right Kotlin mapping.
 */
@Serializable
data class DeviceMetrics(
    val deviceId: String,
    val cpu: CpuMetrics,
    val memory: MemoryMetrics,
    val disk: DiskMetrics,
    val uptimeSeconds: Long? = null,
    @Serializable(with = InstantSerializer::class) val collectedAt: Instant,
    val error: String? = null,
    val suppressed: Boolean? = null,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()

    /** The connection breaker is cooling down on purpose — not an outright failure. */
    val isSuppressed: Boolean get() = suppressed == true
}

@Serializable
data class CpuMetrics(
    val usagePercent: Double = 0.0,
    val cores: Int = 0,
    val modelName: String = "",
    val loadAvg1: Double = 0.0,
    val loadAvg5: Double = 0.0,
    val loadAvg15: Double = 0.0,
)

@Serializable
data class MemoryMetrics(
    val total: Long = 0,
    val used: Long = 0,
    val free: Long = 0,
    val available: Long = 0,
    val usagePercent: Double = 0.0,
    val swapTotal: Long = 0,
    val swapUsed: Long = 0,
    val swapFree: Long = 0,
)

@Serializable
data class DiskMetrics(val partitions: List<Partition>? = null)

@Serializable
data class Partition(
    val mountPoint: String,
    val device: String = "",
    val total: Long = 0,
    val used: Long = 0,
    val free: Long = 0,
    val usagePercent: Double = 0.0,
)

@Serializable
data class MetricsSnapshotResponse(
    val devices: Map<String, DeviceMetrics> = emptyMap(),
    @Serializable(with = InstantSerializer::class) val collectedAt: Instant,
)

@Serializable
data class HealthResponse(val status: String, val version: String = "")
