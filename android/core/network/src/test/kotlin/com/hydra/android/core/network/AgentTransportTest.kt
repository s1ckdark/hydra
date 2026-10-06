package com.hydra.android.core.network

import com.hydra.android.core.model.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private class AgentTestConfig(@Volatile var url: String, var key: String? = "server-auth") : ServerConfigProvider {
    override fun baseUrl() = url
    override fun apiKey() = key
}

class AgentTransportTest {
    private lateinit var server: MockWebServer
    private lateinit var config: AgentTestConfig
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val progress = "event: progress\ndata: {\"run_id\":\"run-A\",\"phase\":\"planning\",\"nodes\":[],\"edges\":[]}\n\n"
    private val final = "event: chat_result\ndata: {\"type\":\"ask\",\"message\":\"ready\",\"run_id\":\"run-A\"}\n\n"

    @Before fun setup() { server = MockWebServer().also { it.start() }; config = AgentTestConfig(server.url("/").toString()) }
    @After fun teardown() { server.shutdown() }
    private fun transport() = OkHttpAgentStreamTransport(agentHttpClient(config), config, json)
    private fun response(body: String) = MockResponse().setHeader("Content-Type", "text/event-stream").setBody(body)

    @Test fun `progress is delivered before delayed final with one POST`() = runBlocking {
        server.enqueue(response(progress + final).throttleBody(progress.toByteArray().size.toLong(), 1, TimeUnit.SECONDS))
        val first = CompletableDeferred<Unit>()
        val events = mutableListOf<AgentStreamEvent>()
        val job = launch { transport().send(ChatRequest(emptyList(), "hello")).collect { events += it; if (it is AgentStreamEvent.Progress) first.complete(Unit) } }
        withTimeout(3_000) { first.await() }
        assertFalse(job.isCompleted)
        assertEquals(1, events.size)
        withTimeout(3_000) { job.join() }
        assertTrue(events.last() is AgentStreamEvent.ChatResult)
        assertEquals(1, server.requestCount)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/agent/chat?stream=1", request.path)
        assertEquals("Bearer server-auth", request.getHeader("Authorization"))
    }

    @Test fun `same-response JSON fallback preserves exact selection and revision with one request`() = runBlocking {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody("""{"results":[],"summary":"done","run_id":"run-A"}"""))
        val selection = AgentModelSelection("orch-A", "worker-A", "cloud-A", "openai", "Exact-ID:2026", "override", teamRevision = "revision-A")
        val request = AgentExecuteRequest(AgentPlan("approved"), selection, "run-A", config.url)
        val result = transport().execute(request).toList().single() as AgentStreamEvent.ExecuteResult
        assertEquals("run-A", result.response.runId)
        val wire = server.takeRequest()
        assertEquals("/api/agent/execute?stream=1", wire.path)
        val body = wire.body.readUtf8()
        assertTrue(body.contains("\"model\":\"Exact-ID:2026\""))
        assertTrue(body.contains("\"team_revision\":\"revision-A\""))
        assertTrue(body.contains("\"connection_id\":\"cloud-A\""))
        assertFalse(body.contains("expectedServerUrl"))
        assertEquals(1, server.requestCount)
    }

    @Test fun `EOF partial final and explicit server error are distinguishable`() = runBlocking {
        for ((body, confirmed) in listOf(progress to false, (progress + final.trimEnd()) to false, "event: error\ndata: {\"error\":\"Plan rejected\"}\n\n" to true)) {
            server.enqueue(response(body))
            val failure = runCatching { transport().send(ChatRequest(emptyList(), "hello")).toList() }.exceptionOrNull()
            assertTrue(failure is AgentStreamException)
            assertEquals(confirmed, (failure as AgentStreamException).serverConfirmed)
        }
        assertEquals(3, server.requestCount)
    }

    @Test fun `disconnect during execute does not replay the mutation`() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        server.enqueue(MockResponse().setBody("{}"))
        val failure = runCatching { transport().execute(AgentExecuteRequest(AgentPlan("approved"))).toList() }.exceptionOrNull()
        assertTrue(failure is AgentStreamException)
        assertFalse((failure as AgentStreamException).serverConfirmed)
        assertEquals(1, server.requestCount)
    }

    @Test fun `retryable statuses and redirects do not cause a second POST`() = runBlocking {
        val redirect = MockWebServer().also { it.start() }
        try {
            for (status in listOf(307, 308, 408, 421, 503)) {
                server.enqueue(MockResponse().setResponseCode(status).setHeader("Location", redirect.url("/target"))
                    .setHeader("Retry-After", "0").setHeader("Content-Type", "application/json").setBody("""{"error":"blocked"}"""))
                val before = server.requestCount
                val failure = runCatching { transport().execute(AgentExecuteRequest(AgentPlan("approved"))).toList() }.exceptionOrNull()
                assertTrue("status=$status", failure is AgentStreamException)
                assertEquals(before + 1, server.requestCount)
                assertEquals(0, redirect.requestCount)
            }
        } finally { redirect.shutdown() }
    }

    @Test fun `cancelling during a blocked body read immediately cancels OkHttp call`() = runBlocking {
        val call = AtomicReference<Call>()
        val client = agentHttpClient(config).newBuilder().addInterceptor { chain -> call.set(chain.call()); chain.proceed(chain.request()) }.build()
        server.enqueue(response(progress).setHeader("Content-Length", progress.toByteArray().size + 10000))
        val first = CompletableDeferred<Unit>()
        val job = launch { OkHttpAgentStreamTransport(client, config, json).send(ChatRequest(emptyList(), "hello")).collect { first.complete(Unit) } }
        withTimeout(3_000) { first.await() }
        withTimeout(2_000) { job.cancelAndJoin() }
        assertTrue(call.get().isCanceled())
        assertEquals(1, server.requestCount)
    }

    @Test fun `queued stream keeps original server identity and rejects a switch`() = runBlocking {
        val next = MockWebServer().also { it.start() }
        try {
            val flow = transport().execute(AgentExecuteRequest(AgentPlan("approved"), expectedServerUrl = config.url))
            config.url = next.url("/").toString()
            val failure = runCatching { flow.toList() }.exceptionOrNull()
            assertTrue(failure is AgentStreamException)
            assertEquals(0, server.requestCount)
            assertEquals(0, next.requestCount)
        } finally { next.shutdown() }
    }

    @Test fun `long idle budget is retained and provider delay does not trigger a second call`() = runBlocking {
        val client = agentHttpClient(config)
        assertEquals(130_000, client.readTimeoutMillis)
        assertEquals(0, client.callTimeoutMillis)
        server.enqueue(response(final).setBodyDelay(250, TimeUnit.MILLISECONDS))
        val result = withTimeout(3_000) { OkHttpAgentStreamTransport(client, config, json).send(ChatRequest(emptyList(), "hello")).toList() }
        assertTrue(result.single() is AgentStreamEvent.ChatResult)
        assertEquals(1, server.requestCount)
    }

    @Test fun `new requests await hydration and never contact initial default`() = runBlocking {
        val ready = CompletableDeferred<Unit>()
        val defaultServer = MockWebServer().also { it.start() }
        var hydrated = false
        val cold = object : ServerConfigProvider {
            override fun baseUrl() = if (hydrated) server.url("/").toString() else defaultServer.url("/").toString()
            override fun apiKey(): String { assertTrue("read credential before URL hydration", hydrated); return "custom-server-key" }
            override fun isReady() = hydrated
            override suspend fun awaitReady() { ready.await() }
        }
        try {
            server.enqueue(response(final))
            val job = launch { OkHttpAgentStreamTransport(agentHttpClient(cold), cold, json).send(ChatRequest(emptyList(), "hello")).toList() }
            delay(50)
            assertEquals(0, defaultServer.requestCount)
            assertEquals(0, server.requestCount)
            hydrated = true; ready.complete(Unit)
            withTimeout(3_000) { job.join() }
            assertEquals(0, defaultServer.requestCount)
            assertEquals("Bearer custom-server-key", server.takeRequest().getHeader("Authorization"))
        } finally { defaultServer.shutdown() }
    }
}
