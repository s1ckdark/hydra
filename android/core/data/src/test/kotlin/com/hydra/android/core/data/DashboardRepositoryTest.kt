package com.hydra.android.core.data

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.GpuMonitorResponse
import com.hydra.android.core.model.GpuNodeStatus
import com.hydra.android.core.model.HealthResponse
import com.hydra.android.core.model.MetricsSnapshotResponse
import com.hydra.android.core.model.NagaTask
import com.hydra.android.core.model.Orch
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.test.runTest
import kotlinx.datetime.Instant
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.IOException

private val T0 = Instant.parse("2026-09-02T10:00:00Z")

private fun device(id: String, status: String = "online", hasGpu: Boolean = false, gpus: Int = 0) =
    Device(id = id, hostname = id, status = status, lastSeen = T0, hasGpu = hasGpu, gpuCount = gpus)

private fun orch(id: String, status: String = "running") =
    Orch(id = id, name = id, status = status, createdAt = T0, updatedAt = T0)

private fun task(id: String, status: String, completed: String? = null) = NagaTask(
    id = id, type = "exec", status = status, createdAt = T0,
    completedAt = completed?.let(Instant::parse),
)

/**
 * Every call fails unless a value is supplied, so each test has to state its
 * own preconditions rather than inherit a convenient default.
 */
private class FakeApi(
    private val healthValue: () -> HealthResponse = { throw IOException("down") },
    private val devicesValue: () -> List<Device> = { throw IOException("down") },
    private val orchsValue: () -> List<Orch> = { throw IOException("down") },
    private val tasksValue: () -> List<NagaTask> = { throw IOException("down") },
    private val gpuValue: () -> GpuMonitorResponse = { throw IOException("down") },
    private val snapshotValue: () -> MetricsSnapshotResponse = { throw IOException("down") },
) : HydraApi {
    var lastRefresh: Boolean? = null
    var lastIncludeMobile: Boolean? = null

    override suspend fun health() = healthValue()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?): List<Device> {
        lastRefresh = refresh
        lastIncludeMobile = includeMobile
        return devicesValue()
    }
    override suspend fun listOrchs() = orchsValue()
    override suspend fun listTasks() = tasksValue()
    override suspend fun gpuMonitor() = gpuValue()
    override suspend fun metricsSnapshot() = snapshotValue()
    override suspend fun chat(body: ChatRequest) = throw UnsupportedOperationException()
    override suspend fun execute(body: AgentExecuteRequest) = throw UnsupportedOperationException()
}

class DashboardRepositoryTest {

    private fun repo(api: HydraApi) = DashboardRepository(api)

    @Test
    fun `auxiliary failures leave their sections empty without setting error`() = runTest {
        // A server with no GPU nodes must not render the whole dashboard as
        // failed. Mirrors loadGPU()'s empty catch in DashboardViewModel.swift.
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { listOf(device("d1")) },
            orchsValue = { listOf(orch("o1")) },
        )
        val snap = repo(api).load(force = false, hideMobile = false)

        assertNull(snap.error)
        assertEquals(1, snap.devices.size)
        assertEquals(1, snap.orchs.size)
        assertTrue(snap.gpuNodes.isEmpty())
        assertTrue(snap.tasks.isEmpty())
        assertTrue(snap.metricsByDevice.isEmpty())
    }

    @Test
    fun `device failure surfaces an error`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            orchsValue = { listOf(orch("o1")) },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertNotNull(snap.error)
        assertEquals("서버에 연결할 수 없습니다", snap.error)
    }

    @Test
    fun `orch failure surfaces the server error body`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { listOf(device("d1")) },
            orchsValue = {
                throw HttpException(
                    Response.error<Any>(
                        500,
                        """{"error":"orch store unavailable"}"""
                            .toResponseBody("application/json".toMediaType()),
                    )
                )
            },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals("orch store unavailable", snap.error)
    }

    @Test
    fun `health failure sets disconnected instead of an error banner`() = runTest {
        val api = FakeApi(
            devicesValue = { listOf(device("d1")) },
            orchsValue = { listOf(orch("o1")) },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals(ServerStatus.DISCONNECTED, snap.serverStatus)
        assertNull(snap.error)
    }

    @Test
    fun `unhealthy status reads as disconnected`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("degraded", "1.0") },
            devicesValue = { emptyList() },
            orchsValue = { emptyList() },
        )
        assertEquals(
            ServerStatus.DISCONNECTED,
            repo(api).load(force = false, hideMobile = false).serverStatus,
        )
    }

    @Test
    fun `force refresh passes refresh true and hideMobile passes include_mobile false`() =
        runTest {
            val api = FakeApi(
                healthValue = { HealthResponse("healthy", "1.0") },
                devicesValue = { emptyList() },
                orchsValue = { emptyList() },
            )
            repo(api).load(force = true, hideMobile = true)
            assertEquals(true, api.lastRefresh)
            assertEquals(false, api.lastIncludeMobile)
        }

    @Test
    fun `unforced load with visible mobiles omits both query params`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { emptyList() },
            orchsValue = { emptyList() },
        )
        repo(api).load(force = false, hideMobile = false)
        assertNull(api.lastRefresh)
        assertNull(api.lastIncludeMobile)
    }

    @Test
    fun `system health is degraded when a device is offline`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { listOf(device("d1"), device("d2", status = "offline")) },
            orchsValue = { emptyList() },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals(SystemHealth.DEGRADED, snap.systemHealth)
        assertEquals(1, snap.onlineDevices.size)
        assertEquals(1, snap.offlineDevices.size)
    }

    @Test
    fun `system health is healthy when every device is online`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { listOf(device("d1")) },
            orchsValue = { emptyList() },
        )
        assertEquals(
            SystemHealth.HEALTHY,
            repo(api).load(force = false, hideMobile = false).systemHealth,
        )
    }

    @Test
    fun `recent tasks are the ten newest by completedAt falling back to createdAt`() = runTest {
        val many = (1..12).map {
            task("t$it", "completed", "2026-09-02T%02d:00:00Z".format(it))
        }
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { emptyList() },
            orchsValue = { emptyList() },
            tasksValue = { many },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals(10, snap.recentTasks.size)
        assertEquals("t12", snap.recentTasks.first().id)
        assertEquals("t3", snap.recentTasks.last().id)
    }

    @Test
    fun `gpu aggregates sum across nodes`() = runTest {
        val api = FakeApi(
            healthValue = { HealthResponse("healthy", "1.0") },
            devicesValue = { listOf(device("d1", hasGpu = true, gpus = 2)) },
            orchsValue = { emptyList() },
            gpuValue = {
                GpuMonitorResponse(
                    timestamp = T0,
                    nodes = listOf(
                        GpuNodeStatus(
                            deviceId = "d1",
                            gpus = listOf(
                                com.hydra.android.core.model.GpuInfo(
                                    index = 0, utilizationPercent = 40.0,
                                    memoryUsedMB = 1024, memoryTotalMB = 2048,
                                ),
                                com.hydra.android.core.model.GpuInfo(
                                    index = 1, utilizationPercent = 60.0,
                                    memoryUsedMB = 1024, memoryTotalMB = 2048,
                                ),
                            ),
                        )
                    ),
                )
            },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals(50.0, snap.avgGpuUtilization, 0.001)
        assertEquals(2.0, snap.totalVramUsedGb, 0.001)
        assertEquals(4.0, snap.totalVramTotalGb, 0.001)
        assertEquals(2, snap.totalGpus)
    }
}
