package com.hydra.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/**
 * One action in an LLM-proposed plan. `args` is free-form JSON mirroring the
 * Go side, shown verbatim rather than enumerating every shape.
 *
 * `id` exists only as a stable LazyColumn key and must never be serialized:
 * AgentPlan is echoed back to POST /api/agent/execute, and iOS excludes it
 * too (AgentPlan.swift:10).
 */
@Serializable
data class AgentAction(
    val type: String,
    val args: JsonObject,
) {
    @Transient
    val id: String = UUID.randomUUID().toString()

    /** "command=uptime deviceId=d1" — sorted key=value summary for the plan card. */
    val argsSummary: String
        get() = args.entries.sortedBy { it.key }
            .joinToString(" ") { (k, v) -> "$k=${v.plainText()}" }
}

/** Strings render without their JSON quotes; everything else as written. */
private fun JsonElement.plainText(): String =
    if (this is JsonPrimitive && isString) content else toString()

@Serializable
data class AgentPlan(val intent: String, val actions: List<AgentAction> = emptyList())

@Serializable
data class ActionResult(
    val type: String,
    val status: String,
    val output: JsonElement? = null,
    val error: String? = null,
) {
    @Transient
    val id: String = UUID.randomUUID().toString()

    val isOk: Boolean get() = status == "ok"
}

@Serializable
data class AgentExecuteRequest(val plan: AgentPlan)

@Serializable
data class AgentExecuteResponse(
    val results: List<ActionResult> = emptyList(),
    /** Natural-language summary generated server-side; the UI computes its own. */
    val summary: String? = null,
)
