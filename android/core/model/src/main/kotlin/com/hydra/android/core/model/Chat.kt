package com.hydra.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Transient
import java.util.UUID

/**
 * One row in the chat history. `role` mirrors the Go side exactly:
 * user | assistant_ask | assistant_plan | system_result.
 *
 * `id` is a LazyColumn key only and is never sent — the outbound history must
 * contain exactly the fields the Go handler expects (ChatTurn.swift:14).
 */
@Serializable
data class ChatTurn(
    val role: String,
    val content: String,
    val plan: AgentPlan? = null,
    val results: List<ActionResult>? = null,
    @Transient val modelSelection: AgentModelSelection? = null,
) {
    @Transient
    val id: String = UUID.randomUUID().toString()
}

@Serializable
data class ChatRequest(
    val history: List<ChatTurn>,
    val message: String,
    /** Per-request system instruction, so the Settings field applies immediately. */
    val instruction: String? = null,
    @SerialName("orchestration_id") val orchestrationId: String? = null,
    @SerialName("agent_id") val agentId: String? = null,
    @Transient val expectedServerUrl: String? = null,
)

/** Either `ask` (clarifying question, no plan) or `plan` (intent + actions). */
@Serializable
data class ChatResponse(
    val type: String,
    val message: String,
    val plan: AgentPlan? = null,
    @SerialName("model_selection") val modelSelection: AgentModelSelection? = null,
    @SerialName("run_id") val runId: String? = null,
)
