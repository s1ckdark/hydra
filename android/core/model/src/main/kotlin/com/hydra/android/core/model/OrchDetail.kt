package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The server binds the coordinator to `coordinator_id` (handler.go:532).
 * iOS sends `head_id`, which this server reads as empty and rejects — do not
 * copy iOS here.
 */
@Serializable
data class CreateOrchRequest(
    val name: String,
    @SerialName("coordinator_id") val coordinatorId: String,
    @SerialName("worker_ids") val workerIds: List<String>,
)

/**
 * No Kotlin default on the timeout, deliberately. kotlinx.serialization omits
 * values equal to their default, so a default here would silently drop
 * `timeout_seconds` from the wire and leave the request relying on the server's
 * own default (30) happening to match ours. The policy lives at the repository
 * boundary instead; this model just says what goes on the wire.
 *
 * The server clamps to 1–300 (handler.go:1699-1714).
 */
@Serializable
data class ExecuteRequest(
    val command: String,
    @SerialName("timeout_seconds") val timeoutSeconds: Int,
)

@Serializable
data class TaskResult(
    val deviceId: String,
    val deviceName: String = "",
    val gpu: String = "",
    val output: String = "",
    val error: String? = null,
    val durationMs: Double = 0.0,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
}

/** Wrapper is snake_case; the results inside are camelCase. */
@Serializable
data class OrchExecuteResponse(
    @SerialName("orch_id") val orchId: String,
    val command: String = "",
    @SerialName("worker_count") val workerCount: Int = 0,
    val results: List<TaskResult> = emptyList(),
)

@Serializable
data class OrchHealth(
    val orchId: String,
    val name: String = "",
    val status: String = "",
    val nodes: List<OrchNodeStatus> = emptyList(),
)

@Serializable
data class OrchNodeStatus(
    val nodeId: String,
    val role: String = "",
    val healthy: Boolean = false,
    val error: String? = null,
)

@Serializable
data class OrchProcessesResponse(
    @SerialName("orch_id") val orchId: String,
    @Serializable(with = InstantSerializer::class) val timestamp: Instant,
    @SerialName("worker_count") val workerCount: Int = 0,
    val workers: List<WorkerStatus> = emptyList(),
)

@Serializable
data class WorkerStatus(
    val deviceId: String,
    val deviceName: String = "",
    val gpu: String? = null,
    val processes: List<WorkerProcess> = emptyList(),
    val error: String? = null,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
    val shortName: String get() = deviceName.substringBefore('.').ifEmpty { deviceId }
    val gpuProcesses: List<WorkerProcess> get() = processes.filter { it.isGpu }
}

@Serializable
data class WorkerProcess(
    /** A string on the wire (handler.go:2170), not an int. */
    val pid: String,
    val processName: String = "",
    val cpuPercent: Double = 0.0,
    val memPercent: Double = 0.0,
    val vramMB: Int = 0,
    val command: String = "",
    val isGpu: Boolean = false,
)
