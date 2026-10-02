package com.hydra.android.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import java.net.URI
import java.util.UUID

object AIProviders {
    val all = listOf("claude", "openai", "zai", "ollama", "lmstudio", "openai_compatible")
    val cloud = setOf("claude", "openai", "zai")
    val local = setOf("ollama", "lmstudio", "openai_compatible")
}

@Serializable
data class AIModelReference(@SerialName("connection_id") val connectionId: String, val model: String)

@Serializable
data class OrchAIConnection(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val provider: String = "claude",
    val endpoint: String = "",
    val models: List<String> = listOf(""),
    @SerialName("has_api_key") val hasApiKey: Boolean = false,
    /** A transient edit only: never decoded from GET or written to local storage. */
    @Transient val apiKey: String? = null,
) {
    fun canKeepStoredKey(original: OrchAIAgents): Boolean = original.connections.any {
        it.id == id && it.provider == provider && it.endpoint == endpoint && it.hasApiKey
    }

    override fun toString(): String = "OrchAIConnection(id=$id, provider=$provider, apiKey=<redacted>)"
}

@Serializable
data class OrchAIAgent(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val role: String = "",
    @SerialName("model_override") val modelOverride: AIModelReference? = null,
)

@Serializable
data class OrchAIAgents(
    val connections: List<OrchAIConnection> = emptyList(),
    @SerialName("head_model") val headModel: AIModelReference? = null,
    val agents: List<OrchAIAgent> = emptyList(),
) {
    val modelReferences: List<AIModelReference> get() = connections.flatMap { c ->
        c.models.filter { it.isNotBlank() }.map { AIModelReference(c.id, it) }
    }
    fun contains(reference: AIModelReference): Boolean = connections.any {
        it.id == reference.connectionId && reference.model in it.models
    }
    fun label(reference: AIModelReference): String =
        "${connections.firstOrNull { it.id == reference.connectionId }?.name ?: reference.connectionId} · ${reference.model}"

    fun validationErrors(original: OrchAIAgents = OrchAIAgents()): List<String> = buildList<String> {
        if (connections.map { it.id }.distinct().size != connections.size || agents.map { it.id }.distinct().size != agents.size) {
            add("Agent and connection IDs must be unique.")
        }
        for (connection in connections) {
            if (connection.id.isBlank() || connection.name.isBlank()) add("Give every connection a name and ID.")
            if (connection.provider !in AIProviders.all) add("Choose a supported provider.")
            if (connection.models.isEmpty() || connection.models.any { it.isBlank() }) add("Enter at least one exact model ID for each connection.")
            if (connection.models.distinct().size != connection.models.size) add("Model IDs must be unique within a connection.")
            if (connection.models.any { it != it.trim() }) add("Remove leading or trailing spaces from model IDs.")
            if (connection.provider in AIProviders.cloud && connection.apiKey.isNullOrBlank() && !connection.canKeepStoredKey(original)) {
                add("Enter an API key for each new or changed cloud connection.")
            }
            if (connection.endpoint.isNotEmpty() || connection.provider in AIProviders.local) {
                val url = runCatching { URI(connection.endpoint) }.getOrNull()
                if (url?.scheme !in listOf("http", "https") || url?.host.isNullOrBlank() || url?.userInfo != null || url?.rawQuery != null || url?.rawFragment != null) {
                    add("Enter an HTTP or HTTPS endpoint without embedded credentials.")
                }
            }
        }
        if (headModel != null && !this@OrchAIAgents.contains(headModel)) add("Select an available head model or use global AI settings.")
        for (agent in agents) {
            if (agent.id.isBlank() || agent.name.isBlank() || agent.role.isBlank()) add("Give every agent a name, ID and role instructions.")
            if (agent.modelOverride != null && !this@OrchAIAgents.contains(agent.modelOverride)) add("An agent refers to a removed connection or model. Choose another model or let the head decide.")
            if (agent.modelOverride == null && modelReferences.isEmpty()) add("Add at least one model for the head to assign to agents.")
        }
    }.distinct()

    fun withoutDraftKeys(): OrchAIAgents = copy(connections = connections.map { it.copy(apiKey = null) })

    fun toUpdate(): OrchAIAgentsUpdate = OrchAIAgentsUpdate(
        connections.map { OrchAIConnectionUpdate(it.id, it.name, it.provider, it.endpoint, it.models, it.apiKey?.trim()?.takeIf(String::isNotEmpty)) },
        headModel, agents,
    )
}

/** Separate write DTO: has_api_key is display metadata, never a credential. */
@Serializable
data class OrchAIConnectionUpdate(
    val id: String,
    val name: String,
    val provider: String,
    val endpoint: String,
    val models: List<String>,
    @SerialName("api_key") val apiKey: String? = null,
) {
    override fun toString(): String = "OrchAIConnectionUpdate(id=$id, provider=$provider, apiKey=<redacted>)"
}

@Serializable
data class OrchAIAgentsUpdate(
    val connections: List<OrchAIConnectionUpdate>,
    @SerialName("head_model") val headModel: AIModelReference? = null,
    val agents: List<OrchAIAgent>,
)

@Serializable
data class AgentModelSelection(
    @SerialName("orchestration_id") val orchestrationId: String,
    @SerialName("agent_id") val agentId: String,
    @SerialName("connection_id") val connectionId: String,
    val provider: String,
    val model: String,
    val source: String,
    val reason: String? = null,
    @SerialName("team_revision") val teamRevision: String? = null,
)

data class AgentChatTarget(
    val orchestrationId: String,
    val orchestrationName: String,
    val agent: OrchAIAgent,
    val modelLabel: String? = null,
)
