package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

/**
 * A reusable command template stored on the device. Deliberately NOT the
 * server's `/api/tasks` queue — that is a different thing with the same name.
 *
 * There is no `schedule` field: the scheduler is out of scope for this cycle,
 * and a field no UI shows would only accumulate data and become a migration
 * problem. Add it when the scheduler arrives.
 */
@Serializable
data class SavedTask(
    val id: String,
    val name: String,
    val command: String,
    /** null = ask which device when the task is run. */
    val targetDeviceId: String? = null,
    val targetDeviceName: String? = null,
    val timeout: Int = 30,
    val priority: TaskPriority = TaskPriority.NORMAL,
    @Serializable(with = InstantSerializer::class) val lastRunAt: Instant? = null,
    val lastRunStatus: String? = null,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
)

enum class TaskPriority { LOW, NORMAL, HIGH, URGENT }
