package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class Orch(
    val id: String,
    val name: String,
    val description: String = "",
    val mode: String = "",
    val status: String,
    val coordinatorId: String = "",
    val workerIds: List<String> = emptyList(),
    val dashboardUrl: String = "",
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    @Serializable(with = InstantSerializer::class) val updatedAt: Instant,
) {
    val workerCount: Int get() = workerIds.size
    val isRunning: Boolean get() = status == "running"
}
