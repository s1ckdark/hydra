package com.hydra.android.feature.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.ChatRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.ActionResult
import com.hydra.android.core.model.AgentChatTarget
import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentModelSelection
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.AgentRunSnapshot
import com.hydra.android.core.model.AgentStreamEvent
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatTurn
import com.hydra.android.core.model.AgentStreamException
import com.hydra.android.core.network.ApiException
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
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
    val selectedAgent: AgentChatTarget? = null,
    val modelSelection: AgentModelSelection? = null,
    val pendingModelSelection: AgentModelSelection? = null,
    val pendingRunId: String? = null,
    val agentRun: AgentRunSnapshot? = null,
    val runOrchestrationId: String? = null,
    val progressDisconnected: Boolean = false,
    val progressUnavailable: Boolean = false,
) {
    val canSwitchAgent: Boolean get() = !isThinking && pendingPlan == null
    val canSend: Boolean get() = !isThinking && pendingPlan == null
}

/** Activity-scoped by HydraApp, so navigation never transfers an old plan to a new agent. */
@HiltViewModel
class ChatViewModel @Inject constructor(
    private val repository: ChatRepository,
    private val settings: SettingsSource,
) : ViewModel() {
    private val _state = MutableStateFlow(ChatUiState())
    val state: StateFlow<ChatUiState> = _state.asStateFlow()
    private var generation = 0L
    private var requestJob: Job? = null
    private var serverUrl: String? = null
    private var pendingServerUrl: String? = null

    init {
        viewModelScope.launch {
            settings.serverUrl.distinctUntilChanged().collect { address ->
                val previous = serverUrl
                serverUrl = address
                if (previous != null && previous != address) {
                    generation++
                    requestJob?.cancel()
                    pendingServerUrl = null
                    _state.value = ChatUiState(error = "서버가 변경되어 이전 대화와 실행 계획을 지웠습니다.")
                }
            }
        }
    }

    fun selectAgent(target: AgentChatTarget?): Boolean {
        if (!_state.value.canSwitchAgent) return false
        if (_state.value.selectedAgent == target) return true
        generation++
        pendingServerUrl = null
        _state.value = ChatUiState(selectedAgent = target)
        return true
    }

    fun send(message: String) {
        val trimmed = message.trim()
        val current = _state.value
        if (trimmed.isEmpty() || !current.canSend) return
        val requestGeneration = ++generation
        val target = current.selectedAgent
        val turns = current.turns + ChatTurn(role = "user", content = trimmed)
        _state.value = current.copy(
            turns = turns, isThinking = true, error = null, agentRun = null,
            runOrchestrationId = target?.orchestrationId,
            progressDisconnected = false, progressUnavailable = false,
        )
        requestJob = viewModelScope.launch {
            var finalized = false
            try {
                val address = settings.serverUrl.first()
                if (serverUrl == null) serverUrl = address
                if (requestGeneration != generation || address != serverUrl) return@launch
                val request = ChatRequest(
                    history = turns, message = trimmed,
                    instruction = settings.aiInstruction.first().trim().takeIf { it.isNotEmpty() },
                    orchestrationId = target?.orchestrationId, agentId = target?.agent?.id,
                    expectedServerUrl = address,
                )
                if (requestGeneration != generation) return@launch
                repository.sendStreaming(request).collect { event ->
                    if (requestGeneration != generation || finalized) return@collect
                    when (event) {
                        is AgentStreamEvent.Progress -> _state.update { state ->
                            if (state.agentRun != null && state.agentRun.runId != event.snapshot.runId) state
                            else state.copy(agentRun = event.snapshot)
                        }
                        is AgentStreamEvent.ChatResult -> {
                            val response = event.response
                            val selection = response.modelSelection
                            if (target != null && (selection == null || selection.orchestrationId != target.orchestrationId ||
                                    selection.agentId != target.agent.id || selection.model.isBlank() || selection.connectionId.isBlank())) {
                                error("서버가 선택한 에이전트의 모델 정보를 반환하지 않았습니다.")
                            }
                            val observedRun = _state.value.agentRun?.runId
                            if (response.runId != null && observedRun != null && response.runId != observedRun) {
                                error("서버가 다른 실행의 결과를 반환했습니다.")
                            }
                            val isPlan = response.type == "plan" && response.plan != null
                            pendingServerUrl = if (isPlan) address else null
                            finalized = true
                            _state.update { state ->
                                state.copy(
                                    turns = state.turns + ChatTurn(
                                        role = if (isPlan) "assistant_plan" else "assistant_ask",
                                        content = response.message, plan = response.plan, modelSelection = selection,
                                    ),
                                    modelSelection = selection,
                                    pendingPlan = response.plan.takeIf { isPlan },
                                    pendingPlanMessage = response.message.takeIf { isPlan },
                                    pendingModelSelection = selection.takeIf { isPlan },
                                    pendingRunId = (response.runId ?: observedRun).takeIf { isPlan },
                                    progressUnavailable = state.agentRun == null,
                                )
                            }
                        }
                        is AgentStreamEvent.ExecuteResult -> error("채팅 요청에 잘못된 실행 결과가 도착했습니다.")
                    }
                }
                if (!finalized && requestGeneration == generation) error("최종 결과를 받기 전에 연결이 종료되었습니다.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                if (requestGeneration == generation && !finalized) {
                    _state.update { it.withFailure(failure).copy(error = failure.message ?: "요청에 실패했습니다.") }
                }
            } finally {
                if (requestGeneration == generation) _state.update { it.copy(isThinking = false) }
            }
        }
    }

    fun runPendingPlan() {
        val current = _state.value
        val plan = current.pendingPlan ?: return
        if (current.isThinking) return
        // Immutable proposal metadata, captured before launching any coroutine.
        val proposalServer = pendingServerUrl
        val request = AgentExecuteRequest(plan, modelSelection = current.pendingModelSelection, runId = current.pendingRunId,
            expectedServerUrl = proposalServer)
        val requestGeneration = ++generation
        _state.update { it.copy(isThinking = true, error = null, progressDisconnected = false) }
        requestJob = viewModelScope.launch {
            var finalized = false
            var receivedProgress = false
            try {
                val address = settings.serverUrl.first()
                if (requestGeneration != generation) return@launch
                check(proposalServer == address && serverUrl == address) { "서버가 변경되어 이 계획을 실행할 수 없습니다." }
                repository.executeStreaming(request).collect { event ->
                    if (requestGeneration != generation || finalized) return@collect
                    when (event) {
                        is AgentStreamEvent.Progress -> {
                            if (request.runId != null && request.runId != event.snapshot.runId) return@collect
                            receivedProgress = true
                            _state.update { state ->
                                state.copy(
                                    agentRun = state.agentRun?.takeIf { it.runId == event.snapshot.runId }
                                        ?.mergeExecution(event.snapshot) ?: event.snapshot,
                                    progressUnavailable = false,
                                )
                            }
                        }
                        is AgentStreamEvent.ExecuteResult -> {
                            val response = event.response
                            if (request.runId != null && response.runId != null && request.runId != response.runId) {
                                error("서버가 다른 실행의 결과를 반환했습니다.")
                            }
                            finalized = true
                            pendingServerUrl = null
                            _state.update { state ->
                                state.copy(
                                    turns = state.turns + ChatTurn(
                                        role = "system_result", content = summarize(response.results),
                                        results = response.results, modelSelection = request.modelSelection,
                                    ),
                                    pendingPlan = null, pendingPlanMessage = null,
                                    pendingModelSelection = null, pendingRunId = null,
                                    progressUnavailable = !receivedProgress,
                                    agentRun = if (receivedProgress) state.agentRun else state.agentRun?.markDisconnected(),
                                )
                            }
                        }
                        is AgentStreamEvent.ChatResult -> error("실행 요청에 잘못된 채팅 결과가 도착했습니다.")
                    }
                }
                if (!finalized && requestGeneration == generation) error("최종 결과를 받기 전에 연결이 종료되었습니다.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                if (requestGeneration == generation && !finalized) {
                    pendingServerUrl = null
                    _state.update {
                        it.withFailure(failure).copy(
                            error = (failure.message ?: "실행 결과를 확인할 수 없습니다.") +
                                "\n실행으로 시스템 상태가 변경되었을 수 있습니다. 새 계획을 요청하기 전에 상태를 확인하세요.",
                            pendingPlan = null, pendingPlanMessage = null, pendingModelSelection = null, pendingRunId = null,
                        )
                    }
                }
            } finally {
                if (requestGeneration == generation) _state.update { it.copy(isThinking = false) }
            }
        }
    }

    fun cancelPendingPlan() {
        val current = _state.value
        if (current.isThinking || current.pendingPlan == null) return
        generation++
        pendingServerUrl = null
        _state.value = current.copy(
            pendingPlan = null, pendingPlanMessage = null, pendingModelSelection = null, pendingRunId = null,
            agentRun = current.agentRun?.cancelApproval(),
        )
    }

    private fun ChatUiState.withFailure(failure: Throwable): ChatUiState {
        val confirmed = (failure as? AgentStreamException)?.serverConfirmed == true ||
            (failure is ApiException && failure.status != null)
        val terminal = agentRun?.phase in setOf("completed", "failed", "cancelled")
        return copy(
            progressUnavailable = agentRun == null,
            progressDisconnected = !confirmed,
            agentRun = if (confirmed && terminal) agentRun else agentRun?.markDisconnected(),
        )
    }

    private fun summarize(results: List<ActionResult>): String {
        val ok = results.count { it.isOk }
        val failed = results.size - ok
        return if (failed == 0) "✓ all $ok action(s) completed"
        else "ran ${results.size} action(s) — $ok ok, $failed failed"
    }
}
