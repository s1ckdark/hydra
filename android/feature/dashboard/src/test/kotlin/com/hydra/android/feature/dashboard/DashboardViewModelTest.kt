package com.hydra.android.feature.dashboard

import app.cash.turbine.test
import com.hydra.android.core.data.DashboardRepository
import com.hydra.android.core.data.DashboardSnapshot
import com.hydra.android.core.data.ServerStatus
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.Device
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val T0 = Instant.parse("2026-09-02T10:00:00Z")

/** Never called; DashboardRepository is subclassed, not exercised through it. */
private object FakeUnusedApi : HydraApi {
    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs() = throw UnsupportedOperationException()
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: ChatRequest) = throw UnsupportedOperationException()
    override suspend fun execute(body: AgentExecuteRequest) = throw UnsupportedOperationException()
}

private class FakeSettings(hideMobile: Boolean = false) : SettingsSource {
    override val serverUrl = MutableStateFlow("http://localhost:8080")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(hideMobile)
    override val sshUsername = MutableStateFlow("root")
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
    override suspend fun setSshUsername(value: String) { sshUsername.value = value }
}

private class RecordingRepository : DashboardRepository(api = FakeUnusedApi) {
    val forceCalls = mutableListOf<Boolean>()
    val hideMobileCalls = mutableListOf<Boolean>()
    var loadCount = 0

    override suspend fun load(force: Boolean, hideMobile: Boolean): DashboardSnapshot {
        forceCalls += force
        hideMobileCalls += hideMobile
        loadCount++
        return DashboardSnapshot(
            serverStatus = ServerStatus.CONNECTED,
            devices = listOf(Device(id = "d1", hostname = "d1", status = "online", lastSeen = T0)),
        )
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class DashboardViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `emits a loaded snapshot on first subscription`() = runTest {
        val vm = DashboardViewModel(RecordingRepository(), FakeSettings())
        vm.state.test {
            assertTrue(awaitItem().isLoading) // initial value
            val loaded = awaitItem()
            assertEquals(1, loaded.snapshot.devices.size)
            assertFalse(loaded.isLoading)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `the blocking loader only shows before anything has arrived`() = runTest {
        val vm = DashboardViewModel(RecordingRepository(), FakeSettings())
        vm.state.test {
            assertTrue(awaitItem().showBlockingLoader)
            assertFalse(awaitItem().showBlockingLoader)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `polls on the interval while subscribed`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem()
            awaitItem()
            advanceTimeBy(5_100)
            awaitItem()
            assertEquals(2, repo.loadCount)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `poll ticks are unforced`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem()
            awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(listOf(false), repo.forceCalls)
    }

    @Test
    fun `refresh forces a cache-bypassing load`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem()
            awaitItem()
            vm.refresh()
            // Awaiting the emission is the only safe wait here: advanceUntilIdle
            // against an infinite poll loop advances virtual time forever.
            awaitItem()
            assertTrue(repo.forceCalls.contains(true))
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `the hide-mobile setting is read on every load`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings(hideMobile = true))
        vm.state.test {
            awaitItem()
            awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(listOf(true), repo.hideMobileCalls)
    }

    @Test
    fun `polling stops when nothing is subscribed`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem()
            awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        val countAtUnsubscribe = repo.loadCount
        // WhileSubscribed(5_000) keeps the loop alive briefly and then stops;
        // the count must not keep climbing for the full 30s.
        advanceTimeBy(30_000)
        assertTrue(
            "load kept running after unsubscribe: $countAtUnsubscribe -> ${repo.loadCount}",
            repo.loadCount - countAtUnsubscribe <= 1,
        )
    }
}
