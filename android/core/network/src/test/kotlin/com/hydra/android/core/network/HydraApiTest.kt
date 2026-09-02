package com.hydra.android.core.network

import com.hydra.android.core.model.ChatRequest
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

class HydraApiTest {
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
    fun `listDevices omits both query params when neither is set`() = runTest {
        server.enqueue(MockResponse().setBody("[]"))
        api.listDevices(refresh = null, includeMobile = null)
        assertEquals("/api/devices", server.takeRequest().path)
    }

    @Test
    fun `listDevices sends refresh and include_mobile when set`() = runTest {
        server.enqueue(MockResponse().setBody("[]"))
        api.listDevices(refresh = true, includeMobile = false)
        val path = server.takeRequest().path!!
        assertTrue(path.contains("refresh=true"))
        assertTrue(path.contains("include_mobile=false"))
    }

    @Test
    fun `health decodes status and version`() = runTest {
        server.enqueue(MockResponse().setBody("""{"status":"healthy","version":"1.2.3"}"""))
        val health = api.health()
        assertEquals("healthy", health.status)
        assertEquals("1.2.3", health.version)
    }

    @Test
    fun `chat decodes a plan response and summarizes its action args`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"type":"plan","message":"run uptime",
                    "plan":{"intent":"check uptime",
                    "actions":[{"type":"exec","args":{"deviceId":"d1","command":"uptime"}}]}}"""
            )
        )
        val resp = api.chat(ChatRequest(history = emptyList(), message = "hi"))
        assertEquals("plan", resp.type)
        assertEquals("check uptime", resp.plan?.intent)
        assertEquals("command=uptime deviceId=d1", resp.plan?.actions?.first()?.argsSummary)
    }

    @Test
    fun `chat posts to the agent endpoint`() = runTest {
        server.enqueue(MockResponse().setBody("""{"type":"ask","message":"which device?"}"""))
        api.chat(ChatRequest(history = emptyList(), message = "hi"))
        val recorded = server.takeRequest()
        assertEquals("POST", recorded.method)
        assertEquals("/api/agent/chat", recorded.path)
    }

    @Test
    fun `snapshot decodes a device-keyed metrics map`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"collectedAt":"2026-09-02T10:00:00Z","devices":{"d1":{
                    "deviceId":"d1",
                    "cpu":{"usagePercent":12.5,"cores":8,"modelName":"M2",
                           "loadAvg1":1.0,"loadAvg5":1.0,"loadAvg15":1.0},
                    "memory":{"total":100,"used":50,"free":50,"available":50,
                              "usagePercent":50.0,"swapTotal":0,"swapUsed":0,"swapFree":0},
                    "disk":{"partitions":null},
                    "collectedAt":"2026-09-02T10:00:00Z"}}}"""
            )
        )
        val snap = api.metricsSnapshot()
        assertEquals(12.5, snap.devices.getValue("d1").cpu.usagePercent, 0.001)
    }

    @Test
    fun `gpu monitor decodes nodes with a node-level error`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"timestamp":"2026-09-02T10:00:00Z","nodeCount":1,
                    "nodes":[{"deviceId":"d1","deviceName":"high15","ip":"100.1.2.3",
                              "gpuModel":"RTX 4090","gpuCount":2,"gpus":null,
                              "error":"nvidia-smi not found"}]}"""
            )
        )
        val node = api.gpuMonitor().nodes.single()
        assertTrue(node.hasError)
        assertEquals("nvidia-smi not found", node.error)
    }
}
