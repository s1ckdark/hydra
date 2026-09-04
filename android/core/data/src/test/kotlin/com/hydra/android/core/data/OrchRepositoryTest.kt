package com.hydra.android.core.data

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.CreateOrchRequest
import com.hydra.android.core.model.ExecuteRequest
import com.hydra.android.core.model.Orch
import com.hydra.android.core.model.OrchExecuteResponse
import com.hydra.android.core.model.OrchHealth
import com.hydra.android.core.model.OrchProcessesResponse
import com.hydra.android.core.model.TaskResult
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.test.runTest
import kotlinx.datetime.Instant
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.IOException

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun orch(id: String) =
    Orch(id = id, name = id, status = "running", createdAt = T0, updatedAt = T0)

/**
 * Every member throws unless a test overrides it, so each test states its own
 * preconditions instead of inheriting a convenient default.
 */
internal open class OrchFakeApi : HydraApi {
    var lastCreate: CreateOrchRequest? = null
    var lastDeleteForce: Boolean? = null
    var lastExecute: ExecuteRequest? = null

    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs(): List<Orch> = listOf(orch("o1"))
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: ChatRequest) = throw UnsupportedOperationException()
    override suspend fun execute(body: AgentExecuteRequest) = throw UnsupportedOperationException()
    override suspend fun createOrch(body: CreateOrchRequest): Orch {
        lastCreate = body
        return orch("o-new")
    }
    override suspend fun deleteOrch(id: String, force: Boolean?) { lastDeleteForce = force }
    override suspend fun orchHealth(id: String) = OrchHealth(orchId = id)
    override suspend fun orchProcesses(id: String) =
        OrchProcessesResponse(orchId = id, timestamp = T0)
    override suspend fun executeOnOrch(id: String, body: ExecuteRequest): OrchExecuteResponse {
        lastExecute = body
        return OrchExecuteResponse(orchId = id)
    }
    override suspend fun executeOnDevice(id: String, body: ExecuteRequest) =
        TaskResult(deviceId = id)
}

class OrchRepositoryTest {

    @Test
    fun `list returns the orchs`() = runTest {
        val result = OrchRepository(OrchFakeApi()).list()
        assertEquals("o1", result.getOrNull()?.single()?.id)
    }

    @Test
    fun `create sends the coordinator and workers`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).create("ray", "d1", listOf("d2", "d3"))
        assertEquals("d1", api.lastCreate?.coordinatorId)
        assertEquals(listOf("d2", "d3"), api.lastCreate?.workerIds)
    }

    @Test
    fun `delete always forces, matching iOS`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).delete("o1")
        assertEquals(true, api.lastDeleteForce)
    }

    @Test
    fun `execute passes the timeout through`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).execute("o1", "uptime", timeout = 45)
        assertEquals(45, api.lastExecute?.timeoutSeconds)
    }

    @Test
    fun `execute defaults the timeout at the repository boundary`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).execute("o1", "uptime")
        assertEquals(30, api.lastExecute?.timeoutSeconds)
    }

    @Test
    fun `a network failure comes back as a failed Result, not an exception`() = runTest {
        val api = object : OrchFakeApi() {
            override suspend fun listOrchs(): List<Orch> = throw IOException("down")
        }
        val result = OrchRepository(api).list()
        assertTrue(result.isFailure)
        assertEquals("서버에 연결할 수 없습니다", result.exceptionOrNull()?.message)
    }

    @Test
    fun `a server error body surfaces its message`() = runTest {
        val api = object : OrchFakeApi() {
            override suspend fun deleteOrch(id: String, force: Boolean?) {
                throw HttpException(
                    Response.error<Any>(
                        409,
                        """{"error":"orch is running"}"""
                            .toResponseBody("application/json".toMediaType()),
                    )
                )
            }
        }
        val result = OrchRepository(api).delete("o1")
        assertEquals("orch is running", result.exceptionOrNull()?.message)
        assertNull(result.getOrNull())
    }
}
