package com.hydra.android.core.network

import com.hydra.android.core.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class AgentApiTest {
    @Test fun `queued team key PUT cannot be routed to a newly selected server`() = runBlocking {
        val first = MockWebServer().also { it.start() }
        val second = MockWebServer().also { it.start() }
        var selected = first.url("/").toString()
        val config = object : ServerConfigProvider { override fun baseUrl() = selected; override fun apiKey() = "server-key" }
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        val api = Retrofit.Builder().baseUrl("http://placeholder.invalid/").client(agentHttpClient(config))
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(AgentApi::class.java)
        try {
            val identity = AgentServerIdentity.capture(config)
            selected = second.url("/").toString()
            val update = OrchAIAgents(connections = listOf(OrchAIConnection("c", "Cloud", "openai", models = listOf("exact"), apiKey = "provider-secret"))).toUpdate()
            assertNotNull(runCatching { api.saveAgents("orch", update, identity) }.exceptionOrNull())
            assertEquals(0, first.requestCount)
            assertEquals(0, second.requestCount)
        } finally { first.shutdown(); second.shutdown() }
    }

    @Test fun `team requests encode exact refs and draft keys while masked GET ignores injected key`() = runBlocking {
        val server = MockWebServer().also { it.start() }
        val config = object : ServerConfigProvider { override fun baseUrl() = server.url("/").toString(); override fun apiKey() = "server-key" }
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        val api = Retrofit.Builder().baseUrl("http://placeholder.invalid/").client(agentHttpClient(config))
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(AgentApi::class.java)
        val masked = """{"connections":[{"id":"connection","name":"Cloud","provider":"openai","models":["Exact-2026"],"has_api_key":true,"api_key":"must-ignore"}],"head_model":{"connection_id":"connection","model":"Exact-2026"},"agents":[{"id":"agent","name":"Analyst","role":"Review","model_override":{"connection_id":"connection","model":"Exact-2026"}}]}"""
        try {
            server.enqueue(MockResponse().setBody(masked))
            val team = api.getAgents("orch/id", AgentServerIdentity.capture(config))
            assertNull(team.connections.single().apiKey)
            val get = server.takeRequest()
            assertEquals("/api/orchs/orch%2Fid/ai-agents", get.path)
            assertEquals("Bearer server-key", get.getHeader("Authorization"))
            server.enqueue(MockResponse().setBody(masked))
            api.saveAgents("orch/id", team.toUpdate(), AgentServerIdentity.capture(config))
            val wire = server.takeRequest().body.readUtf8()
            assertFalse(wire.contains("has_api_key")); assertFalse(wire.contains("api_key"))
            assertTrue(wire.contains("\"connection_id\":\"connection\"")); assertTrue(wire.contains("\"model\":\"Exact-2026\""))
            server.enqueue(MockResponse().setBody(masked))
            api.saveAgents("orch/id", team.copy(connections = team.connections.map { it.copy(apiKey = "new-draft-key") }).toUpdate(), AgentServerIdentity.capture(config))
            assertTrue(server.takeRequest().body.readUtf8().contains("\"api_key\":\"new-draft-key\""))
        } finally { server.shutdown() }
    }

    @Test fun `unsafe URL is rejected before credentials are read`() {
        for (url in listOf("https://user:secret@example.com", "https://example.com?key=secret", "https://example.com#secret", "file:///tmp/x")) {
            val config = object : ServerConfigProvider { override fun baseUrl() = url; override fun apiKey(): String { fail("key read for unsafe URL"); return "key" } }
            assertTrue(runCatching { AgentServerIdentity.capture(config) }.exceptionOrNull() is AgentStreamException)
        }
    }
}
