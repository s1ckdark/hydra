package com.hydra.android.feature.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.ChatRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.ActionResult
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.ChatTurn
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ChatUiState(
    val turns: List<ChatTurn> = emptyList(),
    val isThinking: Boolean = false,
    val pendingPlan: AgentPlan? = null,
    val pendingPlanMessage: String? = null,
    val error: String? = null,
)

@HiltViewModel
class ChatViewModel @Inject constructor(
    private val repository: ChatRepository,
    private val settings: SettingsSource,
) : ViewModel() {

    private val _state = MutableStateFlow(ChatUiState())
    val state: StateFlow<ChatUiState> = _state.asStateFlow()

    fun send(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) return

        _state.update {
            it.copy(
                turns = it.turns + ChatTurn(role = "user", content = trimmed),
                isThinking = true,
                error = null,
            )
        }

        viewModelScope.launch {
            // The repository caps the outbound history at 20; the UI keeps all
            // of it so the user can still scroll back.
            val history = _state.value.turns
            val instruction = settings.aiInstruction.first()

            repository.send(history, trimmed, instruction).fold(
                onSuccess = { response ->
                    val isPlan = response.type == "plan"
                    _state.update {
                        it.copy(
                            turns = it.turns + ChatTurn(
                                role = if (isPlan) "assistant_plan" else "assistant_ask",
                                content = response.message,
                                plan = response.plan,
                            ),
                            isThinking = false,
                            pendingPlan = if (isPlan) response.plan else null,
                            pendingPlanMessage = if (isPlan) response.message else null,
                        )
                    }
                },
                onFailure = { e ->
                    // The user turn stays in history — losing what they typed
                    // because the network failed would be worse than the error.
                    _state.update { it.copy(isThinking = false, error = e.message) }
                },
            )
        }
    }

    fun runPendingPlan() {
        val plan = _state.value.pendingPlan ?: return
        _state.update { it.copy(isThinking = true, error = null) }

        viewModelScope.launch {
            repository.execute(plan).fold(
                onSuccess = { response ->
                    _state.update {
                        it.copy(
                            turns = it.turns + ChatTurn(
                                role = "system_result",
                                content = summarize(response.results),
                                results = response.results,
                            ),
                            isThinking = false,
                            pendingPlan = null,
                            pendingPlanMessage = null,
                        )
                    }
                },
                onFailure = { e ->
                    _state.update { it.copy(isThinking = false, error = e.message) }
                },
            )
        }
    }

    fun cancelPendingPlan() {
        _state.update { it.copy(pendingPlan = null, pendingPlanMessage = null) }
    }

    /** Wording matches iOS ChatViewModel.summary(of:) exactly. */
    private fun summarize(results: List<ActionResult>): String {
        val ok = results.count { it.isOk }
        val failed = results.size - ok
        return if (failed == 0) "✓ all $ok action(s) completed"
        else "ran ${results.size} action(s) — $ok ok, $failed failed"
    }
}
