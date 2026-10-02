package com.hydra.android.feature.chat

import com.hydra.android.core.data.ChatRepository
import com.hydra.android.core.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatAgentViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    @Before fun setup() = Dispatchers.setMain(dispatcher)
    @After fun teardown() = Dispatchers.resetMain()

    @Test fun `partial progress is visible and no plan runs until explicit Run`() = runTest {
        val events = MutableSharedFlow<AgentStreamEvent>(extraBufferCapacity = 8)
        val repository = ScriptedChatRepository().apply { chatEvents = events }
        val vm = ChatViewModel(repository, FakeSettings())
        assertTrue(vm.selectAgent(TARGET))
        vm.send("inspect"); runCurrent()
        events.emit(AgentStreamEvent.Progress(PLANNING)); runCurrent()
        assertTrue(vm.state.value.isThinking)
        assertEquals("run", vm.state.value.agentRun?.runId)
        assertNull(vm.state.value.pendingPlan)
        assertFalse(vm.selectAgent(null))
        assertTrue(repository.executions.isEmpty())
        events.emit(AgentStreamEvent.ChatResult(RESPONSE)); runCurrent()
        // Real transport closes after its final event. This fake remains open;
        // a late duplicate cannot replace the captured plan.
        assertEquals(SELECTION, vm.state.value.pendingModelSelection)
        assertEquals("run", vm.state.value.pendingRunId)
        assertEquals("orch", repository.chats.single().orchestrationId)
        assertEquals("", repository.chats.single().expectedServerUrl)
    }

    @Test fun `Run keeps proposal selection revision and run ID and merges planning history`() = runTest {
        val repository = ScriptedChatRepository()
        val vm = ChatViewModel(repository, FakeSettings())
        vm.selectAgent(TARGET)
        vm.send("inspect"); advanceUntilIdle()
        vm.send("cannot overwrite"); advanceUntilIdle()
        assertEquals(1, repository.chats.size)
        assertFalse(vm.selectAgent(null))
        vm.runPendingPlan(); vm.runPendingPlan(); advanceUntilIdle()
        val request = repository.executions.single()
        assertEquals(SELECTION, request.modelSelection)
        assertEquals("revision", request.modelSelection?.teamRevision)
        assertEquals("run", request.runId)
        assertEquals("", request.expectedServerUrl)
        assertEquals("completed", vm.state.value.agentRun?.nodes?.first { it.id == "head" }?.status)
        assertNull(vm.state.value.pendingPlan)
        assertEquals(SELECTION, vm.state.value.turns.last().modelSelection)
        assertTrue(vm.selectAgent(null))
        assertTrue(vm.state.value.turns.isEmpty())
    }

    @Test fun `cancel only changes the local approval and queued actions`() = runTest {
        val repository = ScriptedChatRepository()
        val vm = ChatViewModel(repository, FakeSettings())
        vm.selectAgent(TARGET); vm.send("inspect"); advanceUntilIdle()
        vm.cancelPendingPlan()
        assertEquals("cancelled", vm.state.value.agentRun?.phase)
        assertEquals("skipped", vm.state.value.agentRun?.nodes?.first { it.id == "action-0" }?.status)
        assertTrue(repository.executions.isEmpty())
        assertNull(vm.state.value.pendingRunId)
        assertNull(vm.state.value.pendingModelSelection)
    }

    @Test fun `uncertain execution retains completed evidence and removes repeat Run`() = runTest {
        val repository = ScriptedChatRepository().apply {
            executionEvents = flow { emit(AgentStreamEvent.Progress(EXECUTING)); throw AgentStreamException("connection lost") }
        }
        val vm = ChatViewModel(repository, FakeSettings())
        vm.selectAgent(TARGET); vm.send("inspect"); advanceUntilIdle()
        vm.runPendingPlan(); advanceUntilIdle()
        assertTrue(vm.state.value.progressDisconnected)
        assertEquals("completed", vm.state.value.agentRun?.nodes?.first { it.id == "head" }?.status)
        assertEquals("unknown", vm.state.value.agentRun?.nodes?.first { it.id == "action-0" }?.status)
        assertNull(vm.state.value.pendingPlan)
        vm.runPendingPlan(); advanceUntilIdle()
        assertEquals(1, repository.executions.size)
    }

    @Test fun `confirmed terminal server errors do not become disconnected`() = runTest {
        for (phase in listOf("failed", "cancelled")) {
            val repository = ScriptedChatRepository().apply {
                executionEvents = flow {
                    emit(AgentStreamEvent.Progress(EXECUTING.copy(phase = phase,
                        nodes = EXECUTING.nodes.map { it.copy(status = phase) })))
                    throw AgentStreamException("server error", serverConfirmed = true)
                }
            }
            val vm = ChatViewModel(repository, FakeSettings())
            vm.selectAgent(TARGET); vm.send("inspect"); advanceUntilIdle()
            vm.runPendingPlan(); advanceUntilIdle()
            assertEquals(phase, vm.state.value.agentRun?.phase)
            assertFalse(vm.state.value.progressDisconnected)
            assertNull(vm.state.value.pendingPlan)
        }
    }

    @Test fun `server change invalidates old target proposal and in flight responses`() = runTest {
        val settings = FakeSettings()
        val repository = ScriptedChatRepository()
        val vm = ChatViewModel(repository, settings)
        vm.selectAgent(TARGET); vm.send("inspect"); advanceUntilIdle()
        settings.serverUrl.value = "https://new.invalid"; runCurrent()
        assertNull(vm.state.value.selectedAgent)
        assertNull(vm.state.value.pendingPlan)
        assertTrue(vm.state.value.turns.isEmpty())
        vm.runPendingPlan(); advanceUntilIdle()
        assertTrue(repository.executions.isEmpty())

        val delayed = MutableSharedFlow<AgentStreamEvent>(extraBufferCapacity = 8)
        repository.chatEvents = delayed
        vm.selectAgent(TARGET); vm.send("new request"); runCurrent()
        assertEquals("https://new.invalid", repository.chats.last().expectedServerUrl)
        settings.serverUrl.value = "https://third.invalid"; runCurrent()
        delayed.emit(AgentStreamEvent.ChatResult(RESPONSE)); runCurrent()
        assertFalse(vm.state.value.isThinking)
        assertNull(vm.state.value.pendingPlan)
        assertTrue(vm.state.value.turns.isEmpty())
    }

    @Test fun `scoped reply must match selected orchestration and agent`() = runTest {
        val repository = ScriptedChatRepository().apply {
            chatEvents = flowOf(AgentStreamEvent.ChatResult(RESPONSE.copy(modelSelection = SELECTION.copy(agentId = "wrong"))))
        }
        val vm = ChatViewModel(repository, FakeSettings())
        vm.selectAgent(TARGET); vm.send("inspect"); advanceUntilIdle()
        assertNotNull(vm.state.value.error)
        assertNull(vm.state.value.pendingPlan)
        assertTrue(repository.executions.isEmpty())
    }

    @Test fun `JSON fallback reports unavailable progress and a new chat starts a fresh tree`() = runTest {
        val repository = ScriptedChatRepository()
        val vm = ChatViewModel(repository, FakeSettings())
        vm.selectAgent(TARGET); vm.send("inspect"); advanceUntilIdle()
        vm.cancelPendingPlan()
        repository.chatEvents = flowOf(AgentStreamEvent.ChatResult(RESPONSE.copy(type = "ask", plan = null, runId = null)))
        vm.send("another task"); advanceUntilIdle()
        assertTrue(vm.state.value.progressUnavailable)
        assertNull(vm.state.value.agentRun)
        assertNull(vm.state.value.pendingPlan)
    }

    companion object {
        val TARGET = AgentChatTarget("orch", "Fixture", OrchAIAgent("agent", "Reviewer", "Review code"))
        val SELECTION = AgentModelSelection("orch", "agent", "connection", "openai", "exact-model", "head", teamRevision = "revision")
        val PLAN = AgentPlan("Inspect", emptyList())
        val RESPONSE = ChatResponse("plan", "Review first", PLAN, SELECTION, "run")
        val PLANNING = AgentRunSnapshot("run", "awaiting_approval", nodes = listOf(
            AgentRunNode("root", kind = "root", title = "Task", status = "waiting", order = 0),
            AgentRunNode("head", "root", "head", "Head", "completed", 10),
            AgentRunNode("agent", "root", "agent", "Reviewer", "completed", 20),
            AgentRunNode("approval", "agent", "approval", "Approval", "waiting", 30),
            AgentRunNode("action-0", "agent", "action", "Inspect", "queued", 40),
        ), edges = listOf(AgentRunEdge("head", "agent", "sequence"), AgentRunEdge("approval", "action-0", "sequence")))
        val EXECUTING = PLANNING.copy(phase = "executing", nodes = PLANNING.nodes.filter { it.id != "head" }.map {
            it.copy(status = if (it.id == "action-0") "running" else "completed")
        })
    }
}

private class ScriptedChatRepository : ChatRepository(FakeUnusedApi) {
    val chats = mutableListOf<ChatRequest>()
    val executions = mutableListOf<AgentExecuteRequest>()
    var chatEvents: Flow<AgentStreamEvent> = flowOf(AgentStreamEvent.Progress(ChatAgentViewModelTest.PLANNING), AgentStreamEvent.ChatResult(ChatAgentViewModelTest.RESPONSE))
    var executionEvents: Flow<AgentStreamEvent> = flowOf(AgentStreamEvent.Progress(ChatAgentViewModelTest.EXECUTING), AgentStreamEvent.ExecuteResult(AgentExecuteResponse(runId = "run")))
    override fun sendStreaming(request: ChatRequest): Flow<AgentStreamEvent> = flow { chats += request; emitAll(chatEvents) }
    override fun executeStreaming(request: AgentExecuteRequest): Flow<AgentStreamEvent> = flow { executions += request; emitAll(executionEvents) }
}
