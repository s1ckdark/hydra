package com.hydra.android.feature.orchs

import androidx.lifecycle.SavedStateHandle
import com.hydra.android.core.data.OrchAgentsRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.AIModelReference
import com.hydra.android.core.model.OrchAIAgent
import com.hydra.android.core.model.OrchAIAgents
import com.hydra.android.core.model.OrchAIConnection
import com.hydra.android.core.network.AgentApi
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val cloudTeam = OrchAIAgents(
    connections = listOf(OrchAIConnection("c1", "Cloud", "openai", "", listOf("exact-model-v2"), true)),
    agents = listOf(OrchAIAgent("a1", "Reviewer", "Find regressions")),
)

private class AgentSettings : SettingsSource {
    override val serverUrl = MutableStateFlow("https://first.example")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(false)
    override val sshUsername = MutableStateFlow("")
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
    override suspend fun setSshUsername(value: String) { sshUsername.value = value }
}

private class AgentTeamRepo : OrchAgentsRepository(
    Proxy.newProxyInstance(AgentApi::class.java.classLoader, arrayOf(AgentApi::class.java)) { _, _, _ ->
        error("Unit tests must never call the network")
    } as AgentApi,
) {
    val gets = mutableListOf<Pair<String, String>>()
    val saves = mutableListOf<Triple<String, String, OrchAIAgents>>()
    var onGet: suspend (String, String) -> Result<OrchAIAgents> = { _, _ -> Result.success(cloudTeam) }
    var onSave: suspend (OrchAIAgents) -> Result<OrchAIAgents> = { Result.success(it) }
    override suspend fun get(id: String, expectedServerUrl: String): Result<OrchAIAgents> {
        gets += id to expectedServerUrl
        return onGet(id, expectedServerUrl)
    }
    override suspend fun save(id: String, configuration: OrchAIAgents, expectedServerUrl: String): Result<OrchAIAgents> {
        saves += Triple(id, expectedServerUrl, configuration)
        return onSave(configuration)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OrchAgentsViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(
        repo: AgentTeamRepo,
        settings: AgentSettings = AgentSettings(),
        handle: SavedStateHandle = SavedStateHandle(mapOf("orchId" to "o1")),
    ) = OrchAgentsViewModel(repo, settings, handle)

    @Test fun `loads configuration for the saved orchestration and pinned server`() = runTest {
        val repo = AgentTeamRepo()
        val vm = viewModel(repo)
        advanceUntilIdle()
        assertEquals(listOf("o1" to "https://first.example"), repo.gets)
        assertEquals(cloudTeam, vm.state.value.configuration)
        assertFalse(vm.state.value.isLoading)
        assertNull(vm.state.value.draft)
    }

    @Test fun `load failure is visible and retry recovers`() = runTest {
        val repo = AgentTeamRepo().apply { onGet = { _, _ -> Result.failure(IllegalStateException("offline")) } }
        val vm = viewModel(repo)
        advanceUntilIdle()
        assertNotNull(vm.state.value.loadError)
        vm.edit()
        assertNull(vm.state.value.draft)
        repo.onGet = { _, _ -> Result.success(cloudTeam) }
        vm.reload()
        advanceUntilIdle()
        assertNull(vm.state.value.loadError)
        assertEquals(cloudTeam, vm.state.value.configuration)
    }

    @Test fun `blank retained key saves and success clears draft keys even with a bad echo`() = runTest {
        val repo = AgentTeamRepo()
        val vm = viewModel(repo)
        advanceUntilIdle()
        vm.edit()
        assertTrue(vm.state.value.canSave)
        vm.updateDraft(cloudTeam.copy(connections = cloudTeam.connections.map { it.copy(apiKey = "typed-test-key") }))
        vm.save()
        advanceUntilIdle()
        assertEquals("typed-test-key", repo.saves.single().third.connections.single().apiKey)
        assertEquals("https://first.example", repo.saves.single().second)
        assertNull(vm.state.value.draft)
        assertNull(vm.state.value.configuration.connections.single().apiKey)
    }

    @Test fun `changed cloud endpoint requires new key and does not save until valid`() = runTest {
        val repo = AgentTeamRepo()
        val vm = viewModel(repo)
        advanceUntilIdle()
        vm.edit()
        vm.updateDraft(cloudTeam.copy(connections = cloudTeam.connections.map { it.copy(endpoint = "https://changed.example") }))
        assertFalse(vm.state.value.canSave)
        vm.save()
        advanceUntilIdle()
        assertTrue(repo.saves.isEmpty())
        assertEquals(cloudTeam, vm.state.value.configuration)
        vm.updateDraft(vm.state.value.draft!!.copy(connections = vm.state.value.draft!!.connections.map { it.copy(apiKey = "new-test-key") }))
        assertTrue(vm.state.value.canSave)
    }

    @Test fun `failed save leaves saved configuration and editable draft intact`() = runTest {
        val repo = AgentTeamRepo().apply { onSave = { Result.failure(IllegalStateException("do not echo secrets")) } }
        val vm = viewModel(repo)
        advanceUntilIdle()
        vm.edit()
        val edited = cloudTeam.copy(connections = cloudTeam.connections.map { it.copy(name = "Changed", apiKey = "ephemeral-key") })
        vm.updateDraft(edited)
        vm.save()
        advanceUntilIdle()
        assertEquals(cloudTeam, vm.state.value.configuration)
        assertEquals(edited, vm.state.value.draft)
        assertNotNull(vm.state.value.saveError)
        assertTrue(vm.state.value.canSave)
        vm.cancelEditor()
        assertNull(vm.state.value.draft)
        vm.edit()
        assertEquals(cloudTeam, vm.state.value.draft)
    }

    @Test fun `duplicate model and removed references block save`() = runTest {
        val repo = AgentTeamRepo()
        val vm = viewModel(repo)
        advanceUntilIdle()
        vm.edit()
        vm.updateDraft(cloudTeam.copy(
            connections = cloudTeam.connections.map { it.copy(models = listOf("duplicate", "duplicate")) },
            headModel = AIModelReference("c1", "missing"),
            agents = listOf(OrchAIAgent("a1", "Reviewer", "Find regressions", AIModelReference("removed", "gone"))),
        ))
        assertEquals(3, vm.state.value.validationErrors.size)
        vm.save()
        advanceUntilIdle()
        assertTrue(repo.saves.isEmpty())
    }

    @Test fun `switching server clears draft and prevents a not yet dispatched save`() = runTest {
        val settings = AgentSettings()
        val repo = AgentTeamRepo()
        val vm = viewModel(repo, settings)
        advanceUntilIdle()
        vm.edit()
        vm.updateDraft(cloudTeam.copy(connections = cloudTeam.connections.map { it.copy(apiKey = "private-test-key") }))
        settings.serverUrl.value = "https://second.example"
        vm.save()
        advanceUntilIdle()
        assertTrue(repo.saves.isEmpty())
        assertNull(vm.state.value.draft)
        assertEquals("o1" to "https://second.example", repo.gets.last())
    }

    @Test fun `late load from another orchestration cannot overwrite the active team`() = runTest {
        val old = CompletableDeferred<Result<OrchAIAgents>>()
        val handle = SavedStateHandle(mapOf("orchId" to "o1"))
        val second = cloudTeam.copy(agents = listOf(OrchAIAgent("second", "Second", "Second role")))
        val repo = AgentTeamRepo().apply {
            onGet = { id, _ -> if (id == "o1") withContext(NonCancellable) { old.await() } else Result.success(second) }
        }
        val vm = viewModel(repo, handle = handle)
        runCurrent()
        handle["orchId"] = "o2"
        runCurrent()
        assertEquals("o2", vm.state.value.orchId)
        old.complete(Result.success(cloudTeam))
        advanceUntilIdle()
        assertEquals(second, vm.state.value.configuration)
    }

    @Test fun `late save from previous server is ignored after server switch`() = runTest {
        val pending = CompletableDeferred<Result<OrchAIAgents>>()
        val settings = AgentSettings()
        val second = cloudTeam.copy(agents = listOf(OrchAIAgent("second", "Second", "Second role")))
        val repo = AgentTeamRepo().apply {
            onGet = { _, url -> Result.success(if (url.contains("second")) second else cloudTeam) }
            onSave = { withContext(NonCancellable) { pending.await() } }
        }
        val vm = viewModel(repo, settings)
        advanceUntilIdle()
        vm.edit()
        vm.save()
        runCurrent()
        assertTrue(vm.state.value.isSaving)
        settings.serverUrl.value = "https://second.example"
        runCurrent()
        pending.complete(Result.success(cloudTeam))
        advanceUntilIdle()
        assertEquals(second, vm.state.value.configuration)
        assertNull(vm.state.value.draft)
        assertFalse(vm.state.value.isSaving)
    }

    @Test fun `cancelled editor ignores a late save and next edit has no typed secret`() = runTest {
        val pending = CompletableDeferred<Result<OrchAIAgents>>()
        val repo = AgentTeamRepo().apply { onSave = { withContext(NonCancellable) { pending.await() } } }
        val vm = viewModel(repo)
        advanceUntilIdle()
        vm.edit()
        vm.updateDraft(cloudTeam.copy(connections = cloudTeam.connections.map { it.copy(apiKey = "draft-key") }))
        vm.save()
        runCurrent()
        vm.cancelEditor()
        pending.complete(Result.success(cloudTeam.copy(agents = emptyList())))
        advanceUntilIdle()
        assertEquals(cloudTeam, vm.state.value.configuration)
        vm.edit()
        assertNull(vm.state.value.draft!!.connections.single().apiKey)
    }

    @Test fun `agent chat target includes exact model label only for fixed agents`() {
        val auto = agentChatTarget("o1", "Team", cloudTeam.agents.single(), cloudTeam)
        assertEquals("o1", auto.orchestrationId)
        assertEquals("Team", auto.orchestrationName)
        assertNull(auto.modelLabel)
        val fixedAgent = cloudTeam.agents.single().copy(modelOverride = AIModelReference("c1", "exact-model-v2"))
        val fixed = agentChatTarget("o1", "Team", fixedAgent, cloudTeam)
        assertEquals(fixedAgent, fixed.agent)
        assertEquals("Cloud · exact-model-v2", fixed.modelLabel)
    }
}
