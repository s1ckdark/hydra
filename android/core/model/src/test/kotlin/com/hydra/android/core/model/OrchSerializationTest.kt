package com.hydra.android.core.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OrchSerializationTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun `create request uses the server's coordinator_id, not iOS's head_id`() {
        // handler.go:532 binds HeadID to `coordinator_id`. iOS sends `head_id`,
        // which this server reads as an empty coordinator and rejects.
        val encoded = json.encodeToString(
            CreateOrchRequest(name = "o1", coordinatorId = "d1", workerIds = listOf("d2", "d3"))
        )
        assertTrue(encoded, encoded.contains("\"coordinator_id\":\"d1\""))
        assertTrue(encoded, encoded.contains("\"worker_ids\":[\"d2\",\"d3\"]"))
        assertTrue("must not send head_id", !encoded.contains("head_id"))
    }

    @Test
    fun `execute request uses timeout_seconds`() {
        val encoded = json.encodeToString(ExecuteRequest(command = "uptime", timeoutSeconds = 30))
        assertTrue(encoded, encoded.contains("\"timeout_seconds\":30"))
    }

    @Test
    fun `orch execute response decodes its snake_case wrapper`() {
        val r = json.decodeFromString<OrchExecuteResponse>(
            """{"orch_id":"o1","command":"uptime","worker_count":2,
               "results":[{"deviceId":"d1","deviceName":"high15","gpu":"",
                           "output":"ok","durationMs":12.5}]}"""
        )
        assertEquals("o1", r.orchId)
        assertEquals(2, r.workerCount)
        assertEquals("high15", r.results.single().deviceName)
        assertEquals(12.5, r.results.single().durationMs, 0.001)
    }

    @Test
    fun `processes response mixes a snake wrapper with camel bodies`() {
        val r = json.decodeFromString<OrchProcessesResponse>(
            """{"orch_id":"o1","timestamp":"2026-09-04T10:00:00Z","worker_count":1,
               "workers":[{"deviceId":"d1","deviceName":"high15","gpu":"RTX 4090",
                 "processes":[{"pid":"4242","processName":"python","cpuPercent":12.0,
                               "memPercent":3.5,"vramMB":2048,"command":"train.py",
                               "isGpu":true}]}]}"""
        )
        val worker = r.workers.single()
        assertEquals("d1", worker.deviceId)
        // pid is a string on the wire (handler.go:2170), not an int.
        assertEquals("4242", worker.processes.single().pid)
        assertTrue(worker.processes.single().isGpu)
    }

    @Test
    fun `a worker with an error and no processes still decodes`() {
        val r = json.decodeFromString<OrchProcessesResponse>(
            """{"orch_id":"o1","timestamp":"2026-09-04T10:00:00Z","worker_count":1,
               "workers":[{"deviceId":"d1","deviceName":"x","error":"unreachable"}]}"""
        )
        val w = r.workers.single()
        assertTrue(w.hasError)
        assertTrue(w.processes.isEmpty())
    }

    @Test
    fun `orch health decodes camelCase throughout`() {
        val h = json.decodeFromString<OrchHealth>(
            """{"orchId":"o1","name":"ray","status":"running",
               "nodes":[{"nodeId":"d1","role":"head","healthy":true},
                        {"nodeId":"d2","role":"worker","healthy":false,"error":"down"}]}"""
        )
        assertEquals("o1", h.orchId)
        assertEquals(2, h.nodes.size)
        assertEquals("down", h.nodes[1].error)
    }

    @Test
    fun `a task result without an error is not an error`() {
        val t = json.decodeFromString<TaskResult>(
            """{"deviceId":"d1","deviceName":"x","gpu":"","output":"hi","durationMs":1.0}"""
        )
        assertTrue(!t.hasError)
    }
}
