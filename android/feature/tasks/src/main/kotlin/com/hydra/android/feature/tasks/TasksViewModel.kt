package com.hydra.android.feature.tasks

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.SavedTaskStore
import com.hydra.android.core.data.TaskRunner
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.SavedTask
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import javax.inject.Inject

/** Everything the screen needs that is not the persisted task list itself. */
data class TasksRuntimeState(
    val runningIds: Set<String> = emptySet(),
    val lastOutputs: Map<String, String> = emptyMap(),
    val devices: List<Device> = emptyList(),
    /** Set when a run needs a device the task does not name. */
    val needsTargetForTaskId: String? = null,
    val error: String? = null,
)

/**
 * The task list and the run-time state are exposed separately rather than
 * combined through `stateIn`: the store already publishes a StateFlow that is
 * always live, and a `WhileSubscribed` wrapper over it would read as its
 * initial value whenever nothing is collecting.
 */
@HiltViewModel
class TasksViewModel @Inject constructor(
    private val store: SavedTaskStore,
    private val runner: TaskRunner,
    devices: DevicesRepository,
) : ViewModel() {

    val tasks: StateFlow<List<SavedTask>> = store.tasks

    private val _runtime = MutableStateFlow(TasksRuntimeState())
    val runtime: StateFlow<TasksRuntimeState> = _runtime.asStateFlow()

    init {
        viewModelScope.launch {
            val online = devices.list().getOrDefault(emptyList()).filter { it.isOnline }
            _runtime.value = _runtime.value.copy(devices = online)
        }
    }

    fun save(task: SavedTask) {
        if (store.tasks.value.any { it.id == task.id }) store.update(task) else store.add(task)
    }

    fun delete(id: String) = store.delete(id)

    /**
     * A task with no target does not get one picked for it — running a command
     * on the wrong machine is not a recoverable mistake.
     */
    fun run(id: String) {
        val task = store.tasks.value.firstOrNull { it.id == id } ?: return
        val target = task.targetDeviceId
        if (target == null) {
            _runtime.value = _runtime.value.copy(needsTargetForTaskId = id, error = null)
            return
        }
        launchRun(task, target)
    }

    fun runOnDevice(id: String, deviceId: String) {
        val task = store.tasks.value.firstOrNull { it.id == id } ?: return
        _runtime.value = _runtime.value.copy(needsTargetForTaskId = null)
        launchRun(task, deviceId)
    }

    fun dismissTargetPrompt() {
        _runtime.value = _runtime.value.copy(needsTargetForTaskId = null)
    }

    private fun launchRun(task: SavedTask, deviceId: String) {
        _runtime.value = _runtime.value.copy(
            runningIds = _runtime.value.runningIds + task.id,
            error = null,
        )
        viewModelScope.launch {
            val result = runner.run(deviceId, task.command, task.timeout)
            val now = Clock.System.now()
            result.fold(
                onSuccess = { r ->
                    store.recordRun(task.id, if (r.hasError) "failed" else "success", now)
                    _runtime.value = _runtime.value.copy(
                        runningIds = _runtime.value.runningIds - task.id,
                        lastOutputs = _runtime.value.lastOutputs + (task.id to r.output),
                        error = r.error,
                    )
                },
                onFailure = { e ->
                    store.recordRun(task.id, "failed", now)
                    _runtime.value = _runtime.value.copy(
                        runningIds = _runtime.value.runningIds - task.id,
                        error = e.message,
                    )
                },
            )
        }
    }
}
