package com.hydra.android.feature.devices

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.model.Device
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest
import javax.inject.Inject

data class DevicesUiState(
    val devices: List<Device> = emptyList(),
    val isLoading: Boolean = true,
    val error: String? = null,
)

@HiltViewModel
class DevicesViewModel @Inject constructor(
    private val repository: DevicesRepository,
) : ViewModel() {

    private val reloads = MutableSharedFlow<Unit>(
        replay = 0,
        extraBufferCapacity = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    @OptIn(ExperimentalCoroutinesApi::class)
    val state: StateFlow<DevicesUiState> = reloads
        .map { }
        .onStart { emit(Unit) }
        .transformLatest {
            val result = repository.list()
            emit(
                DevicesUiState(
                    devices = result.getOrDefault(emptyList()),
                    isLoading = false,
                    error = result.exceptionOrNull()?.message,
                )
            )
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DevicesUiState())

    fun refresh() {
        reloads.tryEmit(Unit)
    }
}
