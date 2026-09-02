package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

/** Task as returned by /api/tasks. */
@Serializable
data class NagaTask(
    val id: String,
    val type: String,
    val status: String,
    val priority: String = "",
    val assignedDeviceId: String? = null,
    val error: String? = null,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    @Serializable(with = InstantSerializer::class) val completedAt: Instant? = null,
    val retryCount: Int = 0,
) {
    val isRunning: Boolean get() = status == "running"
    val isCompleted: Boolean get() = status == "completed"
    val isFailed: Boolean get() = status == "failed"
    val isPending: Boolean
        get() = status == "pending" || status == "queued" || status == "assigned"

    /** Sort key matching iOS `recentTasks`: completedAt ?? createdAt. */
    val sortInstant: Instant get() = completedAt ?: createdAt
}
