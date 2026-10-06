package com.hydra.android.core.data

import com.hydra.android.core.model.*
import com.hydra.android.core.network.AgentApi
import com.hydra.android.core.network.AgentServerIdentity
import com.hydra.android.core.network.ServerConfigProvider
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

private class AgentsFakeApi(var team: OrchAIAgents) : AgentApi {
    var saved: OrchAIAgentsUpdate? = null
    var reads = 0
    var writes = 0
    override suspend fun getAgents(id: String, identity: AgentServerIdentity?): OrchAIAgents { reads++; return team }
    override suspend fun saveAgents(id: String, body: OrchAIAgentsUpdate, identity: AgentServerIdentity?): OrchAIAgents { writes++; saved = body; return team }
}

class OrchAgentsRepositoryTest {
    private fun original() = OrchAIAgents(
        connections = listOf(OrchAIConnection("cloud", "Cloud", "openai", models = listOf("Exact-model"), hasApiKey = true, apiKey = "bad-server-key")),
        agents = listOf(OrchAIAgent("worker", "Analyst", "Review", AIModelReference("cloud", "Exact-model"))),
    )

    @Test fun `masked read baseline retains keys only for unchanged connection identity`() = runTest {
        val api = AgentsFakeApi(original())
        val repository = OrchAgentsRepository(api)
        val masked = repository.get("orch").getOrThrow()
        assertNull(masked.connections.single().apiKey)
        assertTrue(repository.save("orch", masked).isSuccess)
        assertNull(api.saved!!.connections.single().apiKey)
        val changed = masked.copy(connections = masked.connections.map { it.copy(endpoint = "https://new.example/v1") })
        assertTrue(repository.save("orch", changed).isFailure)
        assertEquals(1, api.writes)
        assertTrue(repository.save("orch", changed.copy(connections = changed.connections.map { it.copy(apiKey = "new-key") })).isSuccess)
        assertEquals("new-key", api.saved!!.connections.single().apiKey)
    }

    @Test fun `invalid references never call save and read response keys are stripped again after save`() = runTest {
        val api = AgentsFakeApi(original())
        val repository = OrchAgentsRepository(api)
        val masked = repository.get("orch").getOrThrow()
        assertTrue(repository.save("orch", masked.copy(headModel = AIModelReference("cloud", "invented"))).isFailure)
        assertEquals(0, api.writes)
        val saved = repository.save("orch", masked).getOrThrow()
        assertNull(saved.connections.single().apiKey)
    }

    @Test fun `guarded call rejects switched origin without reading or writing`() = runTest {
        val api = AgentsFakeApi(original())
        val config = object : ServerConfigProvider {
            override fun baseUrl() = "http://server-new:8081"
            override fun apiKey() = "key"
        }
        val repository = OrchAgentsRepository(api, config)
        assertTrue(repository.get("orch", "http://server-old:8081").isFailure)
        assertTrue(repository.save("orch", original(), "http://server-old:8081").isFailure)
        assertEquals(0, api.reads)
        assertEquals(0, api.writes)
    }

    @Test fun `hydration failure fails closed before calling API`() = runTest {
        val api = AgentsFakeApi(original())
        val config = object : ServerConfigProvider {
            override fun baseUrl() = "http://100.125.85.81:8081"
            override fun apiKey(): String { fail("key read before hydration"); return "key" }
            override suspend fun awaitReady() { throw java.io.IOException("SECRET-load-error") }
        }
        val error = OrchAgentsRepository(api, config).get("orch").exceptionOrNull()
        assertNotNull(error)
        assertFalse(error!!.message!!.contains("SECRET"))
        assertEquals(0, api.reads)
    }
}
