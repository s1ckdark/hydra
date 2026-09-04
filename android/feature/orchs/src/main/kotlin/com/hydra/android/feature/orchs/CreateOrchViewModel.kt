package com.hydra.android.feature.orchs

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Device
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class CreateOrchUiState(
    val name: String = "",
    val devices: List<Device> = emptyList(),
    val coordinatorId: String = "",
    val selectedWorkers: Set<String> = emptySet(),
    val isCreating: Boolean = false,
    val created: Boolean = false,
    val error: String? = null,
) {
    val canCreate: Boolean
        get() = name.isNotBlank() && coordinatorId.isNotEmpty() && !isCreating
}

@HiltViewModel
class CreateOrchViewModel @Inject constructor(
    private val orchs: OrchRepository,
    private val devices: DevicesRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(CreateOrchUiState())
    val state: StateFlow<CreateOrchUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            // Only online devices can join an orch, so only those are offered.
            val online = devices.list().getOrDefault(emptyList()).filter { it.isOnline }
            _state.update { it.copy(devices = online) }
        }
    }

    fun onNameChange(value: String) = _state.update { it.copy(name = value, error = null) }

    /** A device cannot be both coordinator and worker. */
    fun onCoordinatorChange(id: String) = _state.update {
        it.copy(coordinatorId = id, selectedWorkers = it.selectedWorkers - id, error = null)
    }

    fun toggleWorker(id: String) = _state.update {
        val next =
            if (id in it.selectedWorkers) it.selectedWorkers - id else it.selectedWorkers + id
        it.copy(selectedWorkers = next)
    }

    fun create() {
        val s = _state.value
        if (!s.canCreate) return
        _state.update { it.copy(isCreating = true, error = null) }
        viewModelScope.launch {
            orchs.create(s.name.trim(), s.coordinatorId, s.selectedWorkers.toList()).fold(
                onSuccess = { _state.update { st -> st.copy(isCreating = false, created = true) } },
                onFailure = { e ->
                    _state.update { st -> st.copy(isCreating = false, error = e.message) }
                },
            )
        }
    }
}
