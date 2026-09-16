package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedTaskSerializationTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val t0 = Instant.parse("2026-09-04T10:00:00Z")

    @Test
    fun `round-trips with defaults`() {
        val task = SavedTask(id = "t1", name = "uptime", command = "uptime", createdAt = t0)
        val decoded = json.decodeFromString<SavedTask>(json.encodeToString(task))
        assertEquals(task, decoded)
        assertEquals(30, decoded.timeout)
        assertEquals(TaskPriority.NORMAL, decoded.priority)
        assertNull(decoded.targetDeviceId)
    }

    @Test
    fun `carries no schedule field`() {
        // The scheduler is out of scope, so the field does not exist: an unused
        // field would accumulate data no UI shows and become a migration problem.
        val encoded = json.encodeToString(
            SavedTask(id = "t1", name = "n", command = "c", createdAt = t0)
        )
        assertTrue(encoded, !encoded.contains("schedule"))
    }

    @Test
    fun `a stored run result survives a round trip`() {
        val task = SavedTask(
            id = "t1", name = "n", command = "c", createdAt = t0,
            lastRunAt = t0, lastRunStatus = "success",
        )
        val decoded = json.decodeFromString<SavedTask>(json.encodeToString(task))
        assertEquals("success", decoded.lastRunStatus)
        assertEquals(t0, decoded.lastRunAt)
    }

    @Test
    fun `an unknown priority in a stored file does not crash the decode`() {
        // Written by a future version; ignoreUnknownKeys does not cover enums,
        // so the store must not hand us a value the enum cannot represent.
        val result = runCatching {
            json.decodeFromString<SavedTask>(
                """{"id":"t1","name":"n","command":"c","priority":"COSMIC",
                   "createdAt":"2026-09-04T10:00:00Z"}"""
            )
        }
        assertTrue("expected a failure the store can catch", result.isFailure)
    }
}
