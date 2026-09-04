package com.hydra.android.feature.orchs

import androidx.lifecycle.SavedStateHandle
import app.cash.turbine.test
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.OrchExecuteResponse
import com.hydra.android.core.model.OrchHealth
import com.hydra.android.core.model.OrchNodeStatus
import com.hydra.android.core.model.OrchProcessesResponse
import com.hydra.android.core.model.TaskResult
import com.hydra.android.core.model.WorkerStatus
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class DetailFakeRepo(
    private val healthResult: Result<OrchHealth> = Result.success(
        OrchHealth(orchId = "o1", nodes = listOf(OrchNodeStatus("d1", "head", true)))
    ),
    private val executeResult: Result<OrchExecuteResponse> = Result.success(
        OrchExecuteResponse(orchId = "o1", results = listOf(TaskResult("d1")))
    ),
) : OrchRepository(api = UnusedApi) {
    var processCalls = 0
    var lastCommand: String? = null

    override suspend fun health(id: String) = healthResult

    override suspend fun processes(id: String): Result<OrchProcessesResponse> {
        processCalls++
        return Result.success(
            OrchProcessesResponse(
                orchId = id,
                timestamp = T0,
                workers = listOf(WorkerStatus(deviceId = "d1", deviceName = "high15.ts.net")),
            )
        )
    }

    override suspend fun execute(
        id: String,
        command: String,
        timeout: Int,
    ): Result<OrchExecuteResponse> {
        lastCommand = command
        return executeResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OrchDetailViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(repo: OrchRepository) =
        OrchDetailViewModel(repo, SavedStateHandle(mapOf("orchId" to "o1")))

    @Test
    fun `health and processes load on first subscription`() = runTest {
        val v = vm(DetailFakeRepo())
        v.state.test {
            awaitItem()
            advanceTimeBy(100)
            val s = expectMostRecentItem()
            assertEquals("d1", s.health?.nodes?.single()?.nodeId)
            assertEquals("high15", s.workers.single().shortName)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `processes poll on the interval while subscribed`() = runTest {
        val repo = DetailFakeRepo()
        val v = vm(repo)
        v.state.test {
            awaitItem()
            // Assert on the call count, not on emissions: with a
            // StandardTestDispatcher nothing runs until time is advanced, so
            // awaiting an emission would just time out on the wall clock.
            advanceTimeBy(100)
            assertEquals(1, repo.processCalls)
            advanceTimeBy(5_100)
            assertEquals(2, repo.processCalls)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `polling stops once nothing is subscribed`() = runTest {
        val repo = DetailFakeRepo()
        val v = vm(repo)
        v.state.test {
            awaitItem()
            advanceTimeBy(100)
            cancelAndIgnoreRemainingEvents()
        }
        val atUnsubscribe = repo.processCalls
        advanceTimeBy(30_000)
        assertTrue(
            "polling kept running: $atUnsubscribe -> ${repo.processCalls}",
            repo.processCalls - atUnsubscribe <= 1,
        )
    }

    @Test
    fun `execute records the result`() = runTest {
        val repo = DetailFakeRepo()
        val v = vm(repo)
        v.state.test {
            awaitItem(); advanceTimeBy(100)
            v.execute("uptime"); advanceTimeBy(100)
            assertEquals("uptime", repo.lastCommand)
            assertEquals(1, expectMostRecentItem().executeResult?.results?.size)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a blank command does not reach the repository`() = runTest {
        val repo = DetailFakeRepo()
        val v = vm(repo)
        v.execute("   ")
        advanceUntilIdle()
        assertNull(repo.lastCommand)
    }

    @Test
    fun `an execute failure surfaces the error`() = runTest {
        val repo = DetailFakeRepo(
            executeResult = Result.failure(ApiException(500, "orch not running"))
        )
        val v = vm(repo)
        v.state.test {
            awaitItem(); advanceTimeBy(100)
            v.execute("uptime"); advanceTimeBy(100)
            assertEquals("orch not running", expectMostRecentItem().error)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
