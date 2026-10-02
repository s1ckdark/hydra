package com.hydra.android.feature.orchs

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.OrchAgentsRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.OrchAIAgents
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

data class OrchAgentsUiState(
    val orchId: String = "",
    val configuration: OrchAIAgents = OrchAIAgents(),
    val isLoading: Boolean = true,
    val loadError: String? = null,
    val draft: OrchAIAgents? = null,
    val isSaving: Boolean = false,
    val saveError: String? = null,
) {
    val validationErrors: List<String> get() = draft?.validationErrors(configuration).orEmpty()
    val canSave: Boolean get() = draft != null && !isSaving && validationErrors.isEmpty()
}

/** Credentials are transient drafts only: never written into SavedStateHandle or preferences. */
@HiltViewModel
class OrchAgentsViewModel @Inject constructor(
    private val repository: OrchAgentsRepository,
    private val settings: SettingsSource,
    savedState: SavedStateHandle,
) : ViewModel() {
    private val selectedOrchId = savedState.getStateFlow("orchId", "")
    private val mutableState = MutableStateFlow(OrchAgentsUiState())
    val state: StateFlow<OrchAgentsUiState> = mutableState.asStateFlow()
    private var identity: Pair<String, String>? = null
    private var generation = 0L
    private var request: Job? = null

    init {
        viewModelScope.launch {
            combine(selectedOrchId, settings.serverUrl) { id, url -> id to url }
                .distinctUntilChanged()
                .collect { target ->
                    identity = target
                    reload()
                }
        }
    }

    fun reload() {
        val target = identity ?: return
        request?.cancel()
        val token = ++generation
        mutableState.value = OrchAgentsUiState(orchId = target.first)
        if (target.first.isBlank()) {
            mutableState.value = mutableState.value.copy(isLoading = false, loadError = "오케스트레이션을 찾을 수 없습니다")
            return
        }
        request = viewModelScope.launch {
            if (!isCurrent(target, token)) return@launch
            val result = repository.get(target.first, target.second)
            if (!isCurrent(target, token)) return@launch
            result.fold(
                onSuccess = { configuration ->
                    mutableState.value = mutableState.value.copy(
                        configuration = configuration.withoutDraftKeys(), isLoading = false,
                    )
                },
                onFailure = {
                    mutableState.value = mutableState.value.copy(
                        isLoading = false, loadError = "AI 에이전트 설정을 불러오지 못했습니다. 다시 시도해 주세요.",
                    )
                },
            )
        }
    }

    fun edit() {
        val current = mutableState.value
        if (current.isLoading || current.loadError != null || current.isSaving) return
        mutableState.value = current.copy(draft = current.configuration.withoutDraftKeys(), saveError = null)
    }

    fun updateDraft(draft: OrchAIAgents) {
        val current = mutableState.value
        if (current.draft == null || current.isSaving) return
        mutableState.value = current.copy(draft = draft, saveError = null)
    }

    /** Also called when the screen leaves composition, so navigation cannot retain a typed key. */
    fun cancelEditor() {
        if (mutableState.value.draft == null) return
        ++generation
        request?.cancel()
        mutableState.value = mutableState.value.copy(draft = null, isSaving = false, saveError = null)
    }

    fun save() {
        val current = mutableState.value
        val target = identity ?: return
        if (!current.canSave || current.orchId != target.first) return
        val draft = current.draft ?: return
        val token = ++generation
        mutableState.value = current.copy(isSaving = true, saveError = null)
        request = viewModelScope.launch {
            if (!isCurrent(target, token)) return@launch
            val result = repository.save(target.first, draft, target.second)
            if (!isCurrent(target, token)) return@launch
            result.fold(
                onSuccess = { saved ->
                    mutableState.value = mutableState.value.copy(
                        configuration = saved.withoutDraftKeys(), draft = null, isSaving = false,
                    )
                },
                onFailure = {
                    // The editable draft survives a failed save; the last saved configuration does too.
                    mutableState.value = mutableState.value.copy(
                        isSaving = false, saveError = "설정을 저장하지 못했습니다. 입력 내용을 확인하고 다시 시도해 주세요.",
                    )
                },
            )
        }
    }

    private suspend fun isCurrent(target: Pair<String, String>, token: Long): Boolean =
        identity == target && generation == token && selectedOrchId.value == target.first &&
            settings.serverUrl.first() == target.second

}
