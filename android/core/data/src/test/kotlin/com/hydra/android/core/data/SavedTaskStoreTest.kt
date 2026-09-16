package com.hydra.android.core.data

import com.hydra.android.core.model.SavedTask
import com.hydra.android.core.model.TaskPriority
import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

private val TS = Instant.parse("2026-09-04T10:00:00Z")

private fun task(id: String, name: String = id) =
    SavedTask(id = id, name = name, command = "uptime", createdAt = TS)

class SavedTaskStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun store(seed: String? = null): Pair<SavedTaskStore, File> {
        val f = File(temp.root, "saved_tasks.json")
        if (seed != null) f.writeText(seed)
        return SavedTaskStore(f) to f
    }

    @Test
    fun `a missing file starts empty`() {
        val (s, _) = store()
        assertTrue(s.tasks.value.isEmpty())
    }

    @Test
    fun `add persists and is readable by a fresh store`() {
        val (s, f) = store()
        s.add(task("t1", "uptime check"))
        assertEquals(1, s.tasks.value.size)
        assertEquals("uptime check", SavedTaskStore(f).tasks.value.single().name)
    }

    @Test
    fun `update replaces by id and keeps order`() {
        val (s, _) = store()
        s.add(task("t1"))
        s.add(task("t2"))
        s.update(task("t1", "renamed"))
        assertEquals(listOf("renamed", "t2"), s.tasks.value.map { it.name })
    }

    @Test
    fun `update of an unknown id is a no-op rather than an insert`() {
        val (s, _) = store()
        s.add(task("t1"))
        s.update(task("ghost"))
        assertEquals(listOf("t1"), s.tasks.value.map { it.id })
    }

    @Test
    fun `delete removes and persists`() {
        val (s, f) = store()
        s.add(task("t1"))
        s.add(task("t2"))
        s.delete("t1")
        assertEquals(listOf("t2"), SavedTaskStore(f).tasks.value.map { it.id })
    }

    @Test
    fun `recordRun stamps status and time`() {
        val (s, f) = store()
        s.add(task("t1"))
        s.recordRun("t1", status = "success", at = TS)
        val stored = SavedTaskStore(f).tasks.value.single()
        assertEquals("success", stored.lastRunStatus)
        assertEquals(TS, stored.lastRunAt)
    }

    @Test
    fun `a malformed file reads as empty rather than throwing`() {
        // A corrupt store must not make the tab unopenable.
        val (s, _) = store(seed = "{ this is not json")
        assertTrue(s.tasks.value.isEmpty())
    }

    @Test
    fun `a file with an unrepresentable enum reads as empty`() {
        val (s, _) = store(
            seed = """[{"id":"t1","name":"n","command":"c","priority":"COSMIC",
                        "createdAt":"2026-09-04T10:00:00Z"}]"""
        )
        assertTrue(s.tasks.value.isEmpty())
    }

    @Test
    fun `writing over a malformed file recovers it`() {
        val (s, f) = store(seed = "garbage")
        s.add(task("t1"))
        assertEquals(listOf("t1"), SavedTaskStore(f).tasks.value.map { it.id })
    }

    @Test
    fun `priority round-trips`() {
        val (s, f) = store()
        s.add(task("t1").copy(priority = TaskPriority.URGENT))
        assertEquals(TaskPriority.URGENT, SavedTaskStore(f).tasks.value.single().priority)
    }

    @Test
    fun `a task with no target device keeps a null target`() {
        val (s, f) = store()
        s.add(task("t1"))
        assertNull(SavedTaskStore(f).tasks.value.single().targetDeviceId)
    }
}
