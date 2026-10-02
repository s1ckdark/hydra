package com.hydra.android.core.data

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import com.hydra.android.core.model.ChatTurn
import com.hydra.android.core.model.AgentStreamEvent
import com.hydra.android.core.model.AgentStreamException
import com.hydra.android.core.network.AgentStreamTransport
import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** History sent to the server is capped; the UI keeps the full list. */
const val SERVER_HISTORY_CAP = 20

/** Open so ViewModel tests can substitute a recording subclass. */
@Singleton
open class ChatRepository @Inject constructor(
    private val api: HydraApi,
    private val transport: AgentStreamTransport? = null,
) {

    open suspend fun send(
        history: List<ChatTurn>,
        message: String,
        instruction: String?,
    ): Result<ChatResponse> = apiCall {
        api.chat(
            ChatRequest(
                history = history.takeLast(SERVER_HISTORY_CAP),
                message = message,
                // A blank Settings field must not become an empty instruction
                // string — the server treats present-but-empty differently.
                instruction = instruction?.trim()?.takeIf { it.isNotEmpty() },
            )
        )
    }

    open suspend fun execute(plan: AgentPlan): Result<AgentExecuteResponse> =
        apiCall { api.execute(AgentExecuteRequest(plan)) }

    open fun sendStreaming(request: ChatRequest): Flow<AgentStreamEvent> {
        val normalized = request.copy(history = request.history.takeLast(SERVER_HISTORY_CAP), instruction = request.instruction?.trim()?.takeIf(String::isNotEmpty))
        return transport?.send(normalized) ?: flow {
            if (request.orchestrationId != null || request.agentId != null) throw AgentStreamException("Scoped agent streaming is unavailable.")
            emit(AgentStreamEvent.ChatResult(send(normalized.history, normalized.message, normalized.instruction).getOrThrow()))
        }
    }

    open fun executeStreaming(request: AgentExecuteRequest): Flow<AgentStreamEvent> =
        transport?.execute(request) ?: flow {
            if (request.modelSelection != null || request.runId != null) throw AgentStreamException("Scoped agent streaming is unavailable.")
            emit(AgentStreamEvent.ExecuteResult(execute(request.plan).getOrThrow()))
        }
}
