package com.hydra.android.feature.chat

import com.hydra.android.core.data.ChatRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.ActionResult
import com.hydra.android.core.model.AgentAction
import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import com.hydra.android.core.model.ChatTurn
import com.hydra.android.core.network.ApiException
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val PLAN = AgentPlan("check uptime", listOf(AgentAction("exec", JsonObject(emptyMap()))))

/** Never called; ChatRepository is subclassed, not exercised through it. */
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

private class FakeChatRepository(
    private val chatResult: Result<ChatResponse> = Result.success(ChatResponse("ask", "hello")),
    private val executeResult: Result<AgentExecuteResponse> =
        Result.success(AgentExecuteResponse()),
) : ChatRepository(api = FakeUnusedApi) {
    var lastHistorySize = -1
    var lastInstruction: String? = null

    override suspend fun send(
        history: List<ChatTurn>,
        message: String,
        instruction: String?,
    ): Result<ChatResponse> {
        lastHistorySize = history.size
        lastInstruction = instruction
        return chatResult
    }

    override suspend fun execute(plan: AgentPlan) = executeResult
}

private class FakeSettings(instruction: String = "") : SettingsSource {
    override val serverUrl = MutableStateFlow("")
    override val aiInstruction = MutableStateFlow(instruction)
    override val hideMobileDevices = MutableStateFlow(false)
    override val sshUsername = MutableStateFlow("root")
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
    override suspend fun setSshUsername(value: String) { sshUsername.value = value }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `an empty message is ignored`() = runTest {
        val repo = FakeChatRepository()
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("   ")
        advanceUntilIdle()
        assertEquals(-1, repo.lastHistorySize)
        assertTrue(vm.state.value.turns.isEmpty())
    }

    @Test
    fun `sending appends the user turn then the assistant reply`() = runTest {
        val vm = ChatViewModel(FakeChatRepository(), FakeSettings())
        vm.send("hi")
        advanceUntilIdle()

        val s = vm.state.value
        assertEquals(2, s.turns.size)
        assertEquals("user", s.turns[0].role)
        assertEquals("hi", s.turns[0].content)
        assertEquals("assistant_ask", s.turns[1].role)
        assertFalse(s.isThinking)
    }

    @Test
    fun `the message is trimmed before it becomes a turn`() = runTest {
        val repo = FakeChatRepository()
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("  hi  ")
        advanceUntilIdle()
        assertEquals("hi", vm.state.value.turns.first().content)
    }

    @Test
    fun `the ai instruction from settings rides along with the request`() = runTest {
        val repo = FakeChatRepository()
        val vm = ChatViewModel(repo, FakeSettings(instruction = "be terse"))
        vm.send("hi")
        advanceUntilIdle()
        assertEquals("be terse", repo.lastInstruction)
    }

    @Test
    fun `a plan response sets the pending plan and an assistant_plan turn`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "will run uptime", PLAN))
        )
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("check uptime")
        advanceUntilIdle()

        val s = vm.state.value
        assertEquals("check uptime", s.pendingPlan?.intent)
        assertEquals("will run uptime", s.pendingPlanMessage)
        assertEquals("assistant_plan", s.turns.last().role)
    }

    @Test
    fun `an ask response leaves no pending plan`() = runTest {
        val vm = ChatViewModel(FakeChatRepository(), FakeSettings())
        vm.send("hi")
        advanceUntilIdle()
        assertNull(vm.state.value.pendingPlan)
        assertNull(vm.state.value.pendingPlanMessage)
    }

    @Test
    fun `running a plan appends a system_result turn summarizing the outcome`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "go", PLAN)),
            executeResult = Result.success(
                AgentExecuteResponse(
                    listOf(
                        ActionResult("exec", "ok"),
                        ActionResult("exec", "error", error = "nope"),
                    )
                )
            ),
        )
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("go"); advanceUntilIdle()
        vm.runPendingPlan(); advanceUntilIdle()

        val last = vm.state.value.turns.last()
        assertEquals("system_result", last.role)
        assertEquals("ran 2 action(s) — 1 ok, 1 failed", last.content)
        assertNull(vm.state.value.pendingPlan)
    }

    @Test
    fun `an all-ok plan run summarizes as completed`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "go", PLAN)),
            executeResult = Result.success(AgentExecuteResponse(listOf(ActionResult("exec", "ok")))),
        )
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("go"); advanceUntilIdle()
        vm.runPendingPlan(); advanceUntilIdle()
        assertEquals("✓ all 1 action(s) completed", vm.state.value.turns.last().content)
    }

    @Test
    fun `running with no pending plan does nothing`() = runTest {
        val vm = ChatViewModel(FakeChatRepository(), FakeSettings())
        vm.runPendingPlan()
        advanceUntilIdle()
        assertTrue(vm.state.value.turns.isEmpty())
        assertFalse(vm.state.value.isThinking)
    }

    @Test
    fun `cancelling clears the pending plan without touching the turns`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "go", PLAN))
        )
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("go"); advanceUntilIdle()
        val before = vm.state.value.turns.size

        vm.cancelPendingPlan()

        assertNull(vm.state.value.pendingPlan)
        assertEquals(before, vm.state.value.turns.size)
    }

    @Test
    fun `a failure surfaces the error and clears thinking`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.failure(ApiException(null, "서버에 연결할 수 없습니다"))
        )
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("hi"); advanceUntilIdle()
        assertEquals("서버에 연결할 수 없습니다", vm.state.value.error)
        assertFalse(vm.state.value.isThinking)
    }

    @Test
    fun `the user turn is kept in history even when the request fails`() = runTest {
        val repo = FakeChatRepository(chatResult = Result.failure(ApiException(500, "boom")))
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("hi"); advanceUntilIdle()
        assertEquals(1, vm.state.value.turns.size)
        assertEquals("user", vm.state.value.turns.first().role)
    }

    @Test
    fun `a following send clears the previous error`() = runTest {
        val repo = FakeChatRepository(chatResult = Result.failure(ApiException(500, "boom")))
        val vm = ChatViewModel(repo, FakeSettings())
        vm.send("hi"); advanceUntilIdle()
        assertEquals("boom", vm.state.value.error)

        val ok = ChatViewModel(FakeChatRepository(), FakeSettings())
        ok.send("hi"); advanceUntilIdle()
        assertNull(ok.state.value.error)
    }
}
