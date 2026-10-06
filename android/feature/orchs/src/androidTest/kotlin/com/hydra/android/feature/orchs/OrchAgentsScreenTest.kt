package com.hydra.android.feature.orchs

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.SavedStateHandle
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.hydra.android.core.data.OrchAgentsRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.AIModelReference
import com.hydra.android.core.model.AgentChatTarget
import com.hydra.android.core.model.OrchAIAgent
import com.hydra.android.core.model.OrchAIAgents
import com.hydra.android.core.model.OrchAIConnection
import com.hydra.android.core.network.AgentApi
import java.io.File
import java.lang.reflect.Proxy
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

private val editorTeam = OrchAIAgents(
    connections = listOf(OrchAIConnection("c1", "Cloud", "openai", "", listOf("exact-model-one", "exact-model-two"), true)),
    agents = listOf(OrchAIAgent("a1", "Reviewer", "Find regressions")),
)

private class EditorRepo : OrchAgentsRepository(
    Proxy.newProxyInstance(AgentApi::class.java.classLoader, arrayOf(AgentApi::class.java)) { _, _, _ ->
        error("Compose tests cannot call a live API")
    } as AgentApi,
) {
    var saved: OrchAIAgents? = null
    var failSave = false
    override suspend fun get(id: String, expectedServerUrl: String) = Result.success(editorTeam)
    override suspend fun save(id: String, configuration: OrchAIAgents, expectedServerUrl: String): Result<OrchAIAgents> {
        if (failSave) return Result.failure(IllegalStateException("offline"))
        saved = configuration
        return Result.success(configuration.withoutDraftKeys())
    }
}

private fun editorSettings() = object : SettingsSource {
    override val serverUrl = MutableStateFlow("https://example.test")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(false)
    override val sshUsername = MutableStateFlow("")
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) = Unit
    override suspend fun setHideMobileDevices(value: Boolean) = Unit
    override suspend fun setSshUsername(value: String) = Unit
}

/** Real form and VM with a fake repository: no credentials, server writes, or model calls. */
class OrchAgentsScreenTest {
    @get:Rule val compose = createComposeRule()

    private fun launch(repo: EditorRepo): OrchAgentsViewModel {
        val vm = OrchAgentsViewModel(repo, editorSettings(), SavedStateHandle(mapOf("orchId" to "o1")))
        compose.setContent {
            MaterialTheme {
                val state by vm.state.collectAsState()
                state.draft?.let { draft ->
                    OrchAgentsEditor("Team", state.configuration, draft, state.isSaving, state.saveError,
                        vm::updateDraft, vm::save, vm::cancelEditor)
                }
            }
        }
        compose.waitUntil(5_000) { !vm.state.value.isLoading }
        compose.runOnIdle { vm.edit() }
        compose.waitForIdle()
        return vm
    }

    @Test fun exactModelAndFixedAgentSelectionReachSave() {
        val repo = EditorRepo()
        val vm = launch(repo)
        compose.onNodeWithTag("orch-connection-model-c1-1").performScrollTo().performTextReplacement("account-model-v3")
        compose.onNodeWithTag("orch-agent-model-a1").performScrollTo().performClick()
        compose.onNodeWithText("Cloud · account-model-v3").performClick()
        compose.waitForIdle()
        val appContext = ApplicationProvider.getApplicationContext<Context>()
        val artifactDirectory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
            ?.takeIf { it.isNotBlank() }?.let(::File)
            ?: requireNotNull(appContext.getExternalFilesDir(null))
        assertTrue(artifactDirectory.isDirectory || artifactDirectory.mkdirs())
        val screenshot = File(artifactDirectory, "orch-ai-agents-editor.png")
        val bitmap = compose.onNodeWithTag("orch-ai-agents-editor").captureToImage().asAndroidBitmap()
        screenshot.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        compose.onNodeWithTag("orch-ai-agents-save").assertIsEnabled().performClick()
        compose.waitUntil(5_000) { repo.saved != null }
        assertEquals(listOf("exact-model-one", "account-model-v3"), repo.saved!!.connections.single().models)
        assertEquals(AIModelReference("c1", "account-model-v3"), repo.saved!!.agents.single().modelOverride)
        assertNull(repo.saved!!.connections.single().apiKey)
        assertNull(vm.state.value.draft)
    }

    @Test fun endpointChangeRequiresANewKeyAndCancelDropsIt() {
        val repo = EditorRepo()
        val vm = launch(repo)
        compose.onNodeWithTag("orch-connection-endpoint-c1").performScrollTo().performTextReplacement("https://changed.example")
        compose.onNodeWithTag("orch-ai-agents-save").assertIsNotEnabled()
        compose.onNodeWithTag("orch-connection-key-c1").performScrollTo().performTextReplacement("fake-test-key")
        compose.onNodeWithTag("orch-ai-agents-save").assertIsEnabled()
        compose.onNodeWithTag("orch-ai-agents-cancel").performClick()
        compose.runOnIdle {
            assertNull(repo.saved)
            assertNull(vm.state.value.draft)
            vm.edit()
            assertNull(vm.state.value.draft!!.connections.single().apiKey)
            assertEquals("", vm.state.value.draft!!.connections.single().endpoint)
        }
    }

    @Test fun duplicateExactModelsDisableSave() {
        val repo = EditorRepo()
        launch(repo)
        compose.onNodeWithTag("orch-connection-model-c1-1").performScrollTo().performTextReplacement("exact-model-one")
        compose.onNodeWithTag("orch-ai-agents-save").assertIsNotEnabled()
        compose.onNodeWithText("같은 연결에 모델 ID를 중복해서 입력할 수 없습니다.").performScrollTo()
        assertNull(repo.saved)
    }

    @Test fun removedFixedModelRequiresAReplacement() {
        val repo = EditorRepo()
        val vm = launch(repo)
        compose.runOnIdle {
            vm.updateDraft(vm.state.value.draft!!.copy(headModel = AIModelReference("c1", "exact-model-two")))
        }
        compose.onNodeWithTag("orch-remove-model-c1-1").performScrollTo().performClick()
        compose.onNodeWithTag("orch-ai-agents-save").assertIsNotEnabled()
        compose.onNodeWithTag("orch-head-model").performScrollTo().performClick()
        compose.onNodeWithText("전역 AI 설정 사용").performClick()
        compose.onNodeWithTag("orch-ai-agents-save").assertIsEnabled()
        assertNull(repo.saved)
    }

    @Test fun failedSaveKeepsFormAndLastSavedConfiguration() {
        val repo = EditorRepo().apply { failSave = true }
        val vm = launch(repo)
        compose.onNodeWithTag("orch-connection-name-c1").performScrollTo().performTextReplacement("Edited connection")
        compose.onNodeWithTag("orch-ai-agents-save").performClick()
        compose.waitUntil(5_000) { vm.state.value.saveError != null }
        compose.onNodeWithTag("orch-ai-agents-save-error").performScrollTo()
        assertEquals("Edited connection", vm.state.value.draft!!.connections.single().name)
        assertEquals("Cloud", vm.state.value.configuration.connections.single().name)
        compose.onNodeWithTag("orch-ai-agents-save").assertIsEnabled()
    }

    @Test fun agentCardMapsTargetAndBlocksSwitchWhileRequestIsPending() {
        var target: AgentChatTarget? = null
        val canSwitch = mutableStateOf(false)
        val fixed = editorTeam.copy(agents = editorTeam.agents.map { it.copy(modelOverride = AIModelReference("c1", "exact-model-two")) })
        compose.setContent {
            MaterialTheme {
                OrchAgentsCard("o1", "Team", OrchAgentsUiState("o1", fixed, isLoading = false),
                    canSwitch.value, {}, {}, { target = it })
            }
        }
        compose.onNodeWithTag("orch-agent-chat-a1").assertIsNotEnabled()
        assertNull(target)
        compose.runOnIdle { canSwitch.value = true }
        compose.onNodeWithTag("orch-agent-chat-a1").assertIsEnabled().performClick()
        compose.runOnIdle {
            assertNotNull(target)
            assertEquals("o1", target!!.orchestrationId)
            assertEquals("Team", target!!.orchestrationName)
            assertEquals("a1", target!!.agent.id)
            assertEquals("Cloud · exact-model-two", target!!.modelLabel)
            assertTrue(target!!.agent.modelOverride != null)
        }
    }
}
