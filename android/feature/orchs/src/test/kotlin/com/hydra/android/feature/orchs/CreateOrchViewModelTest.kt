package com.hydra.android.feature.orchs

import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.Orch
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private fun device(id: String, online: Boolean = true) =
    Device(id = id, hostname = id, status = if (online) "online" else "offline", lastSeen = T0)

private class CreateFakeRepo(
    private val result: Result<Orch> = Result.success(orch("o-new", "starting")),
) : OrchRepository(api = UnusedApi) {
    var created: Triple<String, String, List<String>>? = null
    override suspend fun create(
        name: String,
        coordinatorId: String,
        workerIds: List<String>,
    ): Result<Orch> {
        created = Triple(name, coordinatorId, workerIds)
        return result
    }
}

private class CreateFakeDevices(private val devices: List<Device>) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = Result.success(devices)
}

@OptIn(ExperimentalCoroutinesApi::class)
class CreateOrchViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(
        repo: OrchRepository = CreateFakeRepo(),
        devices: List<Device> = listOf(device("d1"), device("d2"), device("d3", online = false)),
    ) = CreateOrchViewModel(repo, CreateFakeDevices(devices))

    @Test
    fun `only online devices are offered`() = runTest {
        val v = vm()
        advanceUntilIdle()
        assertEquals(listOf("d1", "d2"), v.state.value.devices.map { it.id })
    }

    @Test
    fun `create is disabled until name and coordinator are set`() = runTest {
        val v = vm(); advanceUntilIdle()
        assertFalse(v.state.value.canCreate)
        v.onNameChange("ray")
        assertFalse(v.state.value.canCreate)
        v.onCoordinatorChange("d1")
        assertTrue(v.state.value.canCreate)
    }

    @Test
    fun `selecting the coordinator removes it from the worker set`() = runTest {
        val v = vm(); advanceUntilIdle()
        v.toggleWorker("d1")
        v.onCoordinatorChange("d1")
        assertFalse(v.state.value.selectedWorkers.contains("d1"))
    }

    @Test
    fun `create sends name, coordinator and workers`() = runTest {
        val repo = CreateFakeRepo()
        val v = vm(repo); advanceUntilIdle()
        v.onNameChange("ray")
        v.onCoordinatorChange("d1")
        v.toggleWorker("d2")
        v.create(); advanceUntilIdle()
        assertEquals(Triple("ray", "d1", listOf("d2")), repo.created)
        assertTrue(v.state.value.created)
    }

    @Test
    fun `a failed create surfaces the error and does not report success`() = runTest {
        val repo = CreateFakeRepo(result = Result.failure(ApiException(400, "coordinator required")))
        val v = vm(repo); advanceUntilIdle()
        v.onNameChange("ray"); v.onCoordinatorChange("d1")
        v.create(); advanceUntilIdle()
        assertEquals("coordinator required", v.state.value.error)
        assertFalse(v.state.value.created)
    }
}
