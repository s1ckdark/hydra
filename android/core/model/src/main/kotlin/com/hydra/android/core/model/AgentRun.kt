package com.hydra.android.core.model

import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Raw strings intentionally tolerate states added by newer servers. */
@Serializable
data class AgentRunNode(
    val id: String,
    @SerialName("parent_id") val parentId: String? = null,
    val kind: String,
    val title: String,
    val status: String,
    val order: Int,
    @SerialName("agent_id") val agentId: String? = null,
    val provider: String? = null,
    val model: String? = null,
    @SerialName("action_type") val actionType: String? = null,
    @SerialName("started_at") @Serializable(with = InstantSerializer::class) val startedAt: Instant? = null,
    @SerialName("finished_at") @Serializable(with = InstantSerializer::class) val finishedAt: Instant? = null,
    val message: String? = null,
)

@Serializable
data class AgentRunEdge(val from: String, val to: String, val kind: String)

@Serializable
data class AgentRunSnapshot(
    @SerialName("run_id") val runId: String,
    val phase: String,
    @SerialName("updated_at") @Serializable(with = InstantSerializer::class) val updatedAt: Instant? = null,
    val nodes: List<AgentRunNode> = emptyList(),
    val edges: List<AgentRunEdge> = emptyList(),
) {
    val orderedNodes: List<AgentRunNode> get() = nodes.sortedWith(compareBy({ it.order }, { it.id }))
    val activeNodes: List<AgentRunNode> get() = orderedNodes.filter { it.kind != "root" && it.status in setOf("running", "waiting") }

    fun mergeExecution(next: AgentRunSnapshot): AgentRunSnapshot {
        if (runId != next.runId) return next
        val changed = next.nodes.map { it.id }.toSet()
        val merged = (next.nodes + nodes.filter { it.id !in changed }).distinctBy { it.id }
        val valid = merged.map { it.id }.toSet()
        val replacements = next.edges.map { it.from to it.to }.toSet()
        val mergedEdges = (next.edges + edges.filter { (it.from to it.to) !in replacements })
            .filter { it.from in valid && it.to in valid }.distinct()
        return next.copy(nodes = merged.sortedWith(compareBy({ it.order }, { it.id })), edges = mergedEdges)
    }

    fun markDisconnected(): AgentRunSnapshot = copy(
        phase = "unknown",
        nodes = nodes.map { if (it.status in setOf("running", "waiting")) it.copy(status = "unknown") else it },
    )

    fun cancelApproval(at: Instant = Clock.System.now()): AgentRunSnapshot = copy(
        phase = "cancelled", updatedAt = at,
        nodes = nodes.map {
            when {
                it.kind == "approval" || it.kind == "root" || it.status == "waiting" -> it.copy(status = "cancelled", finishedAt = at)
                it.status == "queued" -> it.copy(status = "skipped")
                else -> it
            }
        },
    )
}

sealed interface AgentStreamEvent {
    data class Progress(val snapshot: AgentRunSnapshot) : AgentStreamEvent
    data class ChatResult(val response: ChatResponse) : AgentStreamEvent
    data class ExecuteResult(val response: AgentExecuteResponse) : AgentStreamEvent
}

/** False means an execution outcome may be unknown; callers must never retry automatically. */
class AgentStreamException(
    override val message: String,
    val serverConfirmed: Boolean = false,
) : Exception(message)
