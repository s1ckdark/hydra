package com.hydra.android.feature.tasks

import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.SavedTaskStore
import com.hydra.android.core.data.TaskRunner
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.SavedTask
import com.hydra.android.core.model.TaskResult
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun task(id: String, target: String? = "d1") =
    SavedTask(id = id, name = id, command = "uptime", targetDeviceId = target, createdAt = T0)

private class FakeRunner(
    private val result: Result<TaskResult> =
        Result.success(TaskResult(deviceId = "d1", output = "ok")),
) : TaskRunner {
    var ranOn: String? = null
    override suspend fun run(deviceId: String, command: String, timeout: Int): Result<TaskResult> {
        ranOn = deviceId
        return result
    }
}

private class FakeDevices(private val devices: List<Device> = emptyList()) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = Result.success(devices)
}

@OptIn(ExperimentalCoroutinesApi::class)
class TasksViewModelTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun store() = SavedTaskStore(File(temp.root, "saved_tasks.json"))

    private fun vm(
        s: SavedTaskStore = store(),
        runner: FakeRunner = FakeRunner(),
    ) = TasksViewModel(s, runner, FakeDevices()) to runner

    @Test
    fun `the list reflects the store`() = runTest {
        val s = store()
        s.add(task("t1"))
        val (v, _) = vm(s)
        assertEquals(listOf("t1"), v.tasks.value.map { it.id })
    }

    @Test
    fun `save adds a new task and updates an existing one`() = runTest {
        val s = store()
        val (v, _) = vm(s)
        v.save(task("t1", target = "d1"))
        assertEquals(1, v.tasks.value.size)
        v.save(task("t1").copy(name = "renamed"))
        assertEquals(listOf("renamed"), v.tasks.value.map { it.name })
    }

    @Test
    fun `delete removes the task`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, _) = vm(s)
        v.delete("t1")
        assertTrue(v.tasks.value.isEmpty())
    }

    @Test
    fun `running marks the task running then records success`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, runner) = vm(s)
        v.run("t1"); advanceUntilIdle()
        assertEquals("d1", runner.ranOn)
        assertEquals("success", v.tasks.value.single().lastRunStatus)
        assertTrue(v.runtime.value.runningIds.isEmpty())
    }

    @Test
    fun `a failed run records failure and surfaces the message`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, _) = vm(s, FakeRunner(Result.failure(ApiException(500, "device unreachable"))))
        v.run("t1"); advanceUntilIdle()
        assertEquals("failed", v.tasks.value.single().lastRunStatus)
        assertEquals("device unreachable", v.runtime.value.error)
    }

    @Test
    fun `a task with no target device asks instead of dialing`() = runTest {
        val s = store(); s.add(task("t1", target = null))
        val (v, runner) = vm(s)
        v.run("t1"); advanceUntilIdle()
        assertNull("must not pick a device on its own", runner.ranOn)
        assertEquals("t1", v.runtime.value.needsTargetForTaskId)
    }

    @Test
    fun `choosing a target runs the task on it`() = runTest {
        val s = store(); s.add(task("t1", target = null))
        val (v, runner) = vm(s)
        v.run("t1"); advanceUntilIdle()
        v.runOnDevice("t1", "d9"); advanceUntilIdle()
        assertEquals("d9", runner.ranOn)
        assertNull(v.runtime.value.needsTargetForTaskId)
    }

    @Test
    fun `the run output is kept for the row`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, _) = vm(s)
        v.run("t1"); advanceUntilIdle()
        assertEquals("ok", v.runtime.value.lastOutputs["t1"])
    }
}
