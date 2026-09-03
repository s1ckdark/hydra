package com.hydra.android.feature.devices

import app.cash.turbine.test
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.model.Device
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
import org.junit.Test

private val T0 = Instant.parse("2026-09-03T10:00:00Z")

private fun device(id: String, ssh: Boolean = true, status: String = "online") =
    Device(id = id, hostname = id, status = status, lastSeen = T0, sshEnabled = ssh)

private class FakeRepo(private val result: () -> List<Device>) : DevicesRepository {
    var calls = 0
    override suspend fun list(): Result<List<Device>> {
        calls++
        return runCatching { result() }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class DevicesViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `loads devices on first subscription`() = runTest {
        val vm = DevicesViewModel(FakeRepo { listOf(device("d1"), device("d2")) })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals(2, s.devices.size)
            assertNull(s.error)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failure surfaces the message and leaves the list empty`() = runTest {
        val vm = DevicesViewModel(FakeRepo { throw ApiException(null, "서버에 연결할 수 없습니다") })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("서버에 연결할 수 없습니다", s.error)
            assertTrue(s.devices.isEmpty())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `devices without ssh are reported as not selectable`() = runTest {
        val vm = DevicesViewModel(FakeRepo { listOf(device("d1", ssh = false)) })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            assertEquals(false, expectMostRecentItem().devices.single().sshEnabled)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `refresh reloads`() = runTest {
        val repo = FakeRepo { emptyList() }
        val vm = DevicesViewModel(repo)
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            vm.refresh()
            advanceUntilIdle()
            assertEquals(2, repo.calls)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
