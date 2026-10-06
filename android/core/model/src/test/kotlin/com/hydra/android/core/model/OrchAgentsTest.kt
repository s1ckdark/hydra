package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class OrchAgentsTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val reference = AIModelReference("connection-A", "EXACT-model-2026:Q4")
    private fun team() = OrchAIAgents(
        connections = listOf(OrchAIConnection("connection-A", "Cloud", "openai", models = listOf(reference.model), hasApiKey = true)),
        headModel = reference,
        agents = listOf(OrchAIAgent("agent-A", "Analyst", "Inspect the task", reference)),
    )

    @Test fun `GET never decodes provider key and PUT never sends presence flag or blank key`() {
        val value = json.decodeFromString<OrchAIAgents>("""{"connections":[{"id":"c","name":"Cloud","provider":"openai","models":["Exact-v1"],"has_api_key":true,"api_key":"malicious-server-key"}],"agents":[]}""")
        assertNull(value.connections.single().apiKey)
        assertTrue(value.connections.single().hasApiKey)
        for (key in listOf(null, "", "   ")) {
            val write = value.copy(connections = value.connections.map { it.copy(apiKey = key) }).toUpdate()
            val encoded = json.encodeToString(write)
            assertFalse(encoded.contains("api_key"))
            assertFalse(encoded.contains("has_api_key"))
            assertFalse(encoded.contains("malicious-server-key"))
        }
        val draft = value.copy(connections = value.connections.map { it.copy(apiKey = "draft-secret") })
        assertFalse(json.encodeToString(draft).contains("draft-secret"))
        assertTrue(json.encodeToString(draft.toUpdate()).contains("\"api_key\":\"draft-secret\""))
        assertFalse(draft.toString().contains("draft-secret"))
    }

    @Test fun `unchanged identity keeps key but provider endpoint and id changes need new key`() {
        val original = team()
        assertTrue(original.validationErrors(original).isEmpty())
        for (changed in listOf(
            original.connections.single().copy(provider = "claude"),
            original.connections.single().copy(endpoint = "https://new.example/v1"),
            original.connections.single().copy(id = "replacement"),
        )) {
            assertFalse(changed.canKeepStoredKey(original))
            assertTrue(original.copy(connections = listOf(changed)).validationErrors(original).any { it.contains("API key") })
        }
        assertFalse(original.copy(connections = original.connections.map { it.copy(models = listOf("Exact-v1", "Exact-v1")) }).validationErrors(original).isEmpty())
        assertFalse(original.copy(agents = original.agents + original.agents).validationErrors(original).isEmpty())
        assertFalse(original.copy(headModel = reference.copy(model = "invented")).validationErrors(original).isEmpty())
    }

    @Test fun `selection revision and exact model survive request roundtrip while local metadata is excluded`() {
        val selection = AgentModelSelection("orch-A", "agent-A", reference.connectionId, "openai", reference.model, "override", teamRevision = "revision-A")
        val request = AgentExecuteRequest(AgentPlan("approved"), selection, "run-A", expectedServerUrl = "https://private.example")
        val encoded = json.encodeToString(request)
        assertTrue(encoded.contains("\"team_revision\":\"revision-A\""))
        assertTrue(encoded.contains("\"model\":\"EXACT-model-2026:Q4\""))
        assertFalse(encoded.contains("expectedServerUrl"))
        assertFalse(encoded.contains("private.example"))
        assertEquals(selection, json.decodeFromString<AgentExecuteRequest>(encoded).modelSelection)
        val history = json.encodeToString(ChatTurn("assistant_plan", "ready", modelSelection = selection))
        assertFalse(history.contains("model_selection"))
        val chat = json.encodeToString(ChatRequest(emptyList(), "task", orchestrationId = "orch-A", agentId = "agent-A"))
        assertTrue(chat.contains("\"orchestration_id\":\"orch-A\""))
        assertTrue(chat.contains("\"agent_id\":\"agent-A\""))
    }

    @Test fun `progress accepts future states merges only same run and preserves confirmed terminal nodes`() {
        val instant = Instant.parse("2026-10-02T00:00:00Z")
        val planning = AgentRunSnapshot("run-A", "awaiting_approval", instant, listOf(
            AgentRunNode("head", kind = "head", title = "Head", status = "completed", order = 10),
            AgentRunNode("agent", kind = "agent", title = "Analyst", status = "completed", order = 20),
        ), listOf(AgentRunEdge("head", "agent", "sequence")))
        val execution = AgentRunSnapshot("run-A", "executing", nodes = listOf(
            AgentRunNode("root", kind = "root", title = "Root", status = "running", order = 0),
            AgentRunNode("action", parentId = "agent", kind = "action", title = "Action", status = "running", order = 40),
            AgentRunNode("agent", kind = "agent", title = "Analyst", status = "running", order = 20),
        ))
        val merged = planning.mergeExecution(execution)
        assertEquals(listOf("agent", "action"), merged.activeNodes.map { it.id })
        assertTrue(merged.nodes.any { it.id == "head" })
        assertEquals(execution.copy(runId = "other"), planning.mergeExecution(execution.copy(runId = "other")))
        val disconnected = merged.markDisconnected()
        assertEquals("unknown", disconnected.phase)
        assertEquals("completed", disconnected.nodes.first { it.id == "head" }.status)
        assertEquals("unknown", disconnected.nodes.first { it.id == "agent" }.status)
        val future = json.decodeFromString<AgentRunSnapshot>("""{"run_id":"future","phase":"new-phase","nodes":[{"id":"x","kind":"new-kind","title":"Future","status":"new-state","order":1}],"edges":[]}""")
        assertEquals("new-state", future.nodes.single().status)
    }

    @Test fun `cancel approval marks waiting cancelled and queued actions skipped`() {
        val snapshot = AgentRunSnapshot("run", "awaiting_approval", nodes = listOf(
            AgentRunNode("agent", kind = "agent", title = "Agent", status = "completed", order = 20),
            AgentRunNode("approval", kind = "approval", title = "Approve", status = "waiting", order = 30),
            AgentRunNode("action", kind = "action", title = "Action", status = "queued", order = 40),
        )).cancelApproval()
        assertEquals(listOf("completed", "cancelled", "skipped"), snapshot.nodes.map { it.status })
    }
}
