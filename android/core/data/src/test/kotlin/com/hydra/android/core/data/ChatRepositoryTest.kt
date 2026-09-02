package com.hydra.android.core.data

import com.hydra.android.core.model.ActionResult
import com.hydra.android.core.model.AgentAction
import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import com.hydra.android.core.model.ChatTurn
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.IOException

private class ChatFakeApi(
    private val response: () -> ChatResponse = { ChatResponse("ask", "hi") },
    private val executeResponse: () -> AgentExecuteResponse = { AgentExecuteResponse() },
) : HydraApi {
    var lastRequest: ChatRequest? = null
    var lastExecute: AgentExecuteRequest? = null

    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs() = throw UnsupportedOperationException()
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: ChatRequest): ChatResponse {
        lastRequest = body
        return response()
    }
    override suspend fun execute(body: AgentExecuteRequest): AgentExecuteResponse {
        lastExecute = body
        return executeResponse()
    }
}

class ChatRepositoryTest {

    @Test
    fun `outbound history is capped at the last 20 turns`() = runTest {
        val api = ChatFakeApi()
        val history = (1..30).map { ChatTurn(role = "user", content = "m$it") }
        ChatRepository(api).send(history, "next", instruction = null)

        val sent = api.lastRequest!!.history
        assertEquals(20, sent.size)
        assertEquals("m11", sent.first().content)
        assertEquals("m30", sent.last().content)
    }

    @Test
    fun `a short history is sent whole`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(
            listOf(ChatTurn(role = "user", content = "only")), "next", instruction = null,
        )
        assertEquals(1, api.lastRequest!!.history.size)
    }

    @Test
    fun `the message is forwarded verbatim`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(emptyList(), "check uptime", instruction = null)
        assertEquals("check uptime", api.lastRequest!!.message)
    }

    @Test
    fun `a blank instruction is sent as null rather than an empty string`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(emptyList(), "hi", instruction = "   ")
        assertNull(api.lastRequest!!.instruction)
    }

    @Test
    fun `a real instruction is attached`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(emptyList(), "hi", instruction = "be terse")
        assertEquals("be terse", api.lastRequest!!.instruction)
    }

    @Test
    fun `a network failure comes back as a failed Result`() = runTest {
        val api = ChatFakeApi(response = { throw IOException("down") })
        val result = ChatRepository(api).send(emptyList(), "hi", instruction = null)
        assertEquals("서버에 연결할 수 없습니다", result.exceptionOrNull()?.message)
    }

    @Test
    fun `execute forwards the plan verbatim`() = runTest {
        val api = ChatFakeApi()
        val plan = AgentPlan("check", listOf(AgentAction("exec", JsonObject(emptyMap()))))
        ChatRepository(api).execute(plan)
        assertEquals("check", api.lastExecute!!.plan.intent)
        assertEquals("exec", api.lastExecute!!.plan.actions.single().type)
    }

    @Test
    fun `execute surfaces its results`() = runTest {
        val api = ChatFakeApi(
            executeResponse = {
                AgentExecuteResponse(listOf(ActionResult("exec", "ok")))
            }
        )
        val result = ChatRepository(api).execute(AgentPlan("go"))
        assertEquals(1, result.getOrNull()?.results?.size)
    }
}
