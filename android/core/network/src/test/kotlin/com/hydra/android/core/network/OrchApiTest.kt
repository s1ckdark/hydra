package com.hydra.android.core.network

import com.hydra.android.core.model.CreateOrchRequest
import com.hydra.android.core.model.ExecuteRequest
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class OrchApiTest {
    private lateinit var server: MockWebServer
    private lateinit var api: HydraApi

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        api = Retrofit.Builder()
            .baseUrl(server.url("/"))
            .client(OkHttpClient())
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(HydraApi::class.java)
    }

    @After
    fun tearDown() = server.shutdown()

    @Test
    fun `createOrch posts coordinator_id`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"id":"o1","name":"ray","status":"starting","coordinatorId":"d1",
                   "workerIds":["d2"],"createdAt":"2026-09-04T10:00:00Z",
                   "updatedAt":"2026-09-04T10:00:00Z"}"""
            )
        )
        api.createOrch(CreateOrchRequest("ray", "d1", listOf("d2")))
        val recorded = server.takeRequest()
        assertEquals("POST", recorded.method)
        assertEquals("/api/orchs", recorded.path)
        val body = recorded.body.readUtf8()
        assertTrue(body, body.contains("\"coordinator_id\":\"d1\""))
    }

    @Test
    fun `deleteOrch sends force when asked`() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        api.deleteOrch("o1", force = true)
        assertEquals("/api/orchs/o1?force=true", server.takeRequest().path)
    }

    @Test
    fun `deleteOrch omits force when not asked`() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        api.deleteOrch("o1", force = null)
        assertEquals("/api/orchs/o1", server.takeRequest().path)
    }

    @Test
    fun `orchHealth decodes nodes`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"orchId":"o1","name":"ray","status":"running",
                   "nodes":[{"nodeId":"d1","role":"head","healthy":true}]}"""
            )
        )
        val h = api.orchHealth("o1")
        assertEquals("/api/orchs/o1/health", server.takeRequest().path)
        assertEquals("d1", h.nodes.single().nodeId)
    }

    @Test
    fun `orchProcesses decodes the mixed-case payload`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"orch_id":"o1","timestamp":"2026-09-04T10:00:00Z","worker_count":1,
                   "workers":[{"deviceId":"d1","deviceName":"high15",
                     "processes":[{"pid":"1","processName":"py","isGpu":false}]}]}"""
            )
        )
        val p = api.orchProcesses("o1")
        assertEquals("/api/orchs/o1/processes", server.takeRequest().path)
        assertEquals("1", p.workers.single().processes.single().pid)
    }

    @Test
    fun `executeOnOrch posts the command and timeout`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"orch_id":"o1","command":"uptime","worker_count":0,"results":[]}"""
            )
        )
        api.executeOnOrch("o1", ExecuteRequest("uptime", 45))
        val recorded = server.takeRequest()
        assertEquals("/api/orchs/o1/execute", recorded.path)
        val body = recorded.body.readUtf8()
        assertTrue(body, body.contains("\"timeout_seconds\":45"))
    }

    @Test
    fun `executeOnDevice returns a single result`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"deviceId":"d1","deviceName":"high15","gpu":"","output":"ok","durationMs":9.0}"""
            )
        )
        val r = api.executeOnDevice("d1", ExecuteRequest("uptime", 30))
        assertEquals("/api/devices/d1/execute", server.takeRequest().path)
        assertEquals("ok", r.output)
    }
}
