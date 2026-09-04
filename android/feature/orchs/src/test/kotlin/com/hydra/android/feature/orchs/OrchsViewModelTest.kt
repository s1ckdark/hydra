package com.hydra.android.feature.orchs

import app.cash.turbine.test
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.CreateOrchRequest
import com.hydra.android.core.model.ExecuteRequest
import com.hydra.android.core.model.Orch
import com.hydra.android.core.network.ApiException
import com.hydra.android.core.network.HydraApi
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
import org.junit.Test

internal val T0 = Instant.parse("2026-09-04T10:00:00Z")

internal fun orch(id: String, status: String = "running") =
    Orch(id = id, name = id, status = status, createdAt = T0, updatedAt = T0)

/** Never called; the repository is subclassed rather than exercised through it. */
internal object UnusedApi : HydraApi {
    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs() = throw UnsupportedOperationException()
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: ChatRequest) = throw UnsupportedOperationException()
    override suspend fun execute(body: AgentExecuteRequest) = throw UnsupportedOperationException()
    override suspend fun createOrch(body: CreateOrchRequest) = throw UnsupportedOperationException()
    override suspend fun deleteOrch(id: String, force: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun orchHealth(id: String) = throw UnsupportedOperationException()
    override suspend fun orchProcesses(id: String) = throw UnsupportedOperationException()
    override suspend fun executeOnOrch(id: String, body: ExecuteRequest) =
        throw UnsupportedOperationException()
    override suspend fun executeOnDevice(id: String, body: ExecuteRequest) =
        throw UnsupportedOperationException()
}

private class FakeOrchRepo(
    private val listResult: Result<List<Orch>> = Result.success(listOf(orch("o1"), orch("o2"))),
    private val deleteResult: Result<Unit> = Result.success(Unit),
) : OrchRepository(api = UnusedApi) {
    var listCalls = 0
    var deletedId: String? = null
    override suspend fun list(): Result<List<Orch>> { listCalls++; return listResult }
    override suspend fun delete(id: String): Result<Unit> { deletedId = id; return deleteResult }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OrchsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `loads orchs on first subscription`() = runTest {
        val vm = OrchsViewModel(FakeOrchRepo())
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals(2, s.orchs.size)
            assertNull(s.error)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failure surfaces the message and leaves the list empty`() = runTest {
        val repo = FakeOrchRepo(
            listResult = Result.failure(ApiException(null, "서버에 연결할 수 없습니다"))
        )
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("서버에 연결할 수 없습니다", s.error)
            assertTrue(s.orchs.isEmpty())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a successful delete reloads the list`() = runTest {
        val repo = FakeOrchRepo()
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            val before = repo.listCalls
            vm.delete("o1"); advanceUntilIdle()
            assertEquals("o1", repo.deletedId)
            assertTrue("delete should trigger a reload", repo.listCalls > before)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failed delete shows the error and does not remove the row`() = runTest {
        // No optimistic removal: a row that vanishes and reappears is worse
        // than one that never moved.
        val repo = FakeOrchRepo(deleteResult = Result.failure(ApiException(409, "orch is running")))
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            vm.delete("o1"); advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("orch is running", s.error)
            assertEquals(2, s.orchs.size)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `refresh reloads`() = runTest {
        val repo = FakeOrchRepo()
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            val before = repo.listCalls
            vm.refresh(); advanceUntilIdle()
            assertTrue(repo.listCalls > before)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
