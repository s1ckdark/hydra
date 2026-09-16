package com.hydra.android.feature.orchs

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.OrchExecuteResponse
import com.hydra.android.core.model.OrchHealth
import com.hydra.android.core.model.WorkerStatus
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject
import kotlin.time.Duration.Companion.seconds

data class OrchDetailUiState(
    val health: OrchHealth? = null,
    val workers: List<WorkerStatus> = emptyList(),
    val isExecuting: Boolean = false,
    val executeResult: OrchExecuteResponse? = null,
    val error: String? = null,
) {
    /**
     * handler.go labels the head node "coordinator"; "head" is accepted only
     * because the wire name has moved before.
     */
    val headNodeId: String? get() = health?.nodes
        ?.firstOrNull { it.role == "coordinator" || it.role == "head" }
        ?.nodeId
}

@HiltViewModel
class OrchDetailViewModel @Inject constructor(
    private val repository: OrchRepository,
    savedState: SavedStateHandle,
) : ViewModel() {

    private val orchId: String = savedState.get<String>("orchId").orEmpty()

    private val actions = MutableStateFlow(OrchDetailUiState())

    /**
     * Health once, processes every five seconds. The delay sits after a
     * completed load, so a server slower than the interval cannot have each
     * tick cancel the poll in flight — the same shape the dashboard uses.
     * Subscription drives the loop, so leaving the screen stops it.
     *
     * One stateIn, not two: chaining a stateIn over another doubles how long
     * the poll lingers after the last collector goes away, because the outer
     * stage keeps collecting the inner one through its own timeout.
     */
    private val polled = flow {
        val health = repository.health(orchId).getOrNull()
        while (true) {
            val workers = repository.processes(orchId).getOrNull()?.workers.orEmpty()
            emit(health to workers)
            delay(POLL_INTERVAL)
        }
    }

    val state: StateFlow<OrchDetailUiState> =
        combine(polled, actions) { (health, workers), action ->
            action.copy(health = health, workers = workers)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrchDetailUiState())

    fun execute(command: String) {
        val trimmed = command.trim()
        if (trimmed.isEmpty()) return
        actions.value = actions.value.copy(isExecuting = true, error = null, executeResult = null)
        viewModelScope.launch {
            repository.execute(orchId, trimmed).fold(
                onSuccess = { r ->
                    actions.value = actions.value.copy(isExecuting = false, executeResult = r)
                },
                onFailure = { e ->
                    actions.value = actions.value.copy(isExecuting = false, error = e.message)
                },
            )
        }
    }

    private companion object {
        val POLL_INTERVAL = 5.seconds
    }
}
