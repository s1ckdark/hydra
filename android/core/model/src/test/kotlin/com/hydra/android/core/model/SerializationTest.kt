package com.hydra.android.core.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `decodes RFC3339 with fractional seconds`() {
        val task = json.decodeFromString<NagaTask>(
            """{"id":"t1","type":"exec","status":"running","priority":"normal",
               "assignedDeviceId":null,"error":null,
               "createdAt":"2026-09-02T10:00:00.123456789Z",
               "completedAt":null,"retryCount":0}"""
        )
        assertEquals("t1", task.id)
        assertTrue(task.isRunning)
    }

    @Test
    fun `decodes RFC3339 without fractional seconds`() {
        // Go's time.Time omits the fraction when it is zero, so both forms
        // arrive from the same server. iOS handles this at APIClient.swift:20-26.
        val task = json.decodeFromString<NagaTask>(
            """{"id":"t2","type":"exec","status":"completed","priority":"normal",
               "assignedDeviceId":null,"error":null,
               "createdAt":"2026-09-02T10:00:00Z",
               "completedAt":"2026-09-02T10:01:00Z","retryCount":0}"""
        )
        assertEquals("t2", task.id)
        assertTrue(task.isCompleted)
    }

    @Test
    fun `ChatTurn does not serialize its client-side id`() {
        val encoded = json.encodeToString(ChatTurn(role = "user", content = "hi"))
        assertFalse(encoded.contains("\"id\""))
    }

    @Test
    fun `AgentAction and ActionResult do not serialize their client-side ids`() {
        // AgentPlan is echoed back to POST /api/agent/execute, so a leaked id
        // would ride along into the execute request.
        val action = AgentAction(type = "exec", args = buildJsonObject { put("cmd", "ls") })
        assertFalse(json.encodeToString(action).contains("\"id\""))
        val result = ActionResult(type = "exec", status = "ok", output = null, error = null)
        assertFalse(json.encodeToString(result).contains("\"id\""))
    }

    @Test
    fun `AgentAction args survives a decode-encode round trip`() {
        val decoded = json.decodeFromString<AgentAction>(
            """{"type":"exec","args":{"deviceId":"d1","command":"uptime","timeout":30}}"""
        )
        val reencoded = json.encodeToString(decoded)
        assertTrue(reencoded.contains("\"deviceId\":\"d1\""))
        assertTrue(reencoded.contains("\"timeout\":30"))
    }

    @Test
    fun `AgentAction summarizes its args as sorted key equals value pairs`() {
        val decoded = json.decodeFromString<AgentAction>(
            """{"type":"exec","args":{"deviceId":"d1","command":"uptime"}}"""
        )
        assertEquals("command=uptime deviceId=d1", decoded.argsSummary)
    }

    @Test
    fun `Device computes online state and short name`() {
        val d = json.decodeFromString<Device>(
            """{"id":"d1","name":"","hostname":"high15","ipAddresses":["10.0.0.2"],
               "tailscaleIp":"100.1.2.3","os":"linux","status":"online","isExternal":false,
               "tags":null,"user":"dave","lastSeen":"2026-09-02T10:00:00Z",
               "sshEnabled":true,"hasGpu":true,"gpuModel":"RTX 4090","gpuCount":2}"""
        )
        assertTrue(d.isOnline)
        assertEquals("high15", d.displayName)
        assertEquals("high15", d.shortName)
    }

    @Test
    fun `Device falls back to hostname only when name is blank`() {
        val d = json.decodeFromString<Device>(
            """{"id":"d2","name":"Studio","hostname":"studio.local","status":"offline",
               "lastSeen":"2026-09-02T10:00:00Z"}"""
        )
        assertFalse(d.isOnline)
        assertEquals("Studio", d.displayName)
        assertEquals("studio", d.shortName)
    }

    @Test
    fun `NagaTask sorts by completedAt when present and createdAt otherwise`() {
        val completed = json.decodeFromString<NagaTask>(
            """{"id":"a","type":"exec","status":"completed","priority":"p",
               "createdAt":"2026-09-02T10:00:00Z","completedAt":"2026-09-02T12:00:00Z",
               "retryCount":0}"""
        )
        val pending = json.decodeFromString<NagaTask>(
            """{"id":"b","type":"exec","status":"queued","priority":"p",
               "createdAt":"2026-09-02T11:00:00Z","retryCount":0}"""
        )
        assertTrue(completed.sortInstant > pending.sortInstant)
        assertTrue(pending.isPending)
    }

    @Test
    fun `GpuInfo tolerates a server that omits the extended nvidia-smi fields`() {
        val gpu = json.decodeFromString<GpuInfo>(
            """{"index":0,"name":"RTX 4090","utilizationPercent":55.0,
               "memoryUsedMB":8192,"memoryTotalMB":24576,"temperatureC":61,
               "powerDrawW":210.0,"powerLimitW":450.0}"""
        )
        assertEquals(0, gpu.index)
        assertEquals(33.33, gpu.memoryPercent, 0.01)
    }

    @Test
    fun `MetricsSnapshotResponse decodes a device-keyed map`() {
        val snap = json.decodeFromString<MetricsSnapshotResponse>(
            """{"collectedAt":"2026-09-02T10:00:00Z","devices":{"d1":{
               "deviceId":"d1",
               "cpu":{"usagePercent":12.5,"cores":8,"modelName":"M2",
                      "loadAvg1":1.0,"loadAvg5":1.0,"loadAvg15":1.0},
               "memory":{"total":100,"used":50,"free":50,"available":50,
                         "usagePercent":50.0,"swapTotal":0,"swapUsed":0,"swapFree":0},
               "disk":{"partitions":null},
               "collectedAt":"2026-09-02T10:00:00Z"}}}"""
        )
        assertEquals(12.5, snap.devices.getValue("d1").cpu.usagePercent, 0.001)
        assertFalse(snap.devices.getValue("d1").hasError)
    }
}
