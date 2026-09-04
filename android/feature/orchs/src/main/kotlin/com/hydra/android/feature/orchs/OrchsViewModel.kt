package com.hydra.android.feature.orchs

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Orch
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

data class OrchsUiState(
    val orchs: List<Orch> = emptyList(),
    val isLoading: Boolean = true,
    val error: String? = null,
)

@HiltViewModel
class OrchsViewModel @Inject constructor(
    private val repository: OrchRepository,
) : ViewModel() {

    private val reloads = MutableSharedFlow<Unit>(
        replay = 0,
        extraBufferCapacity = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Errors raised by an action (delete), kept separate from load errors. */
    private val actionError = MutableStateFlow<String?>(null)

    /** The last rows the server confirmed, so a failed reload keeps them. */
    private var loadedOrchs: List<Orch> = emptyList()

    @OptIn(ExperimentalCoroutinesApi::class)
    private val loaded: StateFlow<OrchsUiState> = reloads
        .map { }
        .onStart { emit(Unit) }
        .transformLatest {
            // The loading state is emitted through the same flow as the result
            // so the two are ordered. It drives the pull-to-refresh indicator,
            // which means it has to go back up for every reload, not just the
            // first one — and the rows stay put so the list never blinks.
            emit(OrchsUiState(orchs = loadedOrchs, isLoading = true))
            val result = repository.list()
            loadedOrchs = result.getOrDefault(loadedOrchs)
            emit(
                OrchsUiState(
                    orchs = loadedOrchs,
                    isLoading = false,
                    error = result.exceptionOrNull()?.message,
                )
            )
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrchsUiState())

    val state: StateFlow<OrchsUiState> =
        combine(loaded, actionError) { base, action ->
            if (action == null) base else base.copy(error = action)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrchsUiState())

    fun refresh() {
        actionError.value = null
        reloads.tryEmit(Unit)
    }

    /**
     * The list is not touched until the server confirms. Removing the row
     * optimistically and putting it back on failure is a worse experience than
     * a row that simply does not move.
     */
    fun delete(id: String) {
        viewModelScope.launch {
            repository.delete(id).fold(
                onSuccess = {
                    actionError.value = null
                    reloads.tryEmit(Unit)
                },
                onFailure = { actionError.value = it.message },
            )
        }
    }
}
