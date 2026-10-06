package com.hydra.android.feature.chat

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.hydra.android.core.designsystem.AgentTree
import com.hydra.android.core.designsystem.HydraTheme
import com.hydra.android.core.model.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Actual composables driven by immutable fixtures; no network or preferences. */
class AgentChatScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun currentStepUsesMeasuredGeometryAndProgressDoesNotForcePan() {
        val snapshot = mutableStateOf(graph(8))
        compose.setContent { HydraTheme { AgentTree(snapshot.value, false, Modifier.fillMaxWidth()) } }
        compose.onNodeWithTag("agent-tree-current-step").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("agent-tree-node-action-8").assertIsDisplayed()
        val card = compose.onNodeWithTag("agent-tree-node-action-8").fetchSemanticsNode().boundsInRoot
        val viewport = compose.onNodeWithTag("agent-tree-scroll").fetchSemanticsNode().boundsInRoot
        assertTrue(card.top >= viewport.top && card.bottom <= viewport.bottom)
        val before = compose.onNodeWithTag("agent-tree-scroll").fetchSemanticsNode()
            .config[SemanticsProperties.VerticalScrollAxisRange].value()
        compose.runOnIdle { snapshot.value = graph(9) }
        compose.waitForIdle()
        val after = compose.onNodeWithTag("agent-tree-scroll").fetchSemanticsNode()
            .config[SemanticsProperties.VerticalScrollAxisRange].value()
        assertEquals(before, after, 1f)
        compose.onNodeWithTag("agent-tree-current-step").performClick()
        compose.onNodeWithTag("agent-tree-node-action-9").assertIsDisplayed().performClick()
        compose.onNodeWithTag("agent-tree-node-details").assertExists()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val outputDirectory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
            ?.let(::File) ?: context.getExternalFilesDir(null) ?: context.cacheDir
        outputDirectory.mkdirs()
        File(outputDirectory, "agent-tree-current-step.png").outputStream().use { output ->
            compose.onNodeWithTag("agent-tree").captureToImage().asAndroidBitmap()
                .compress(Bitmap.CompressFormat.PNG, 100, output)
        }
    }

    @Test fun pendingPlanNeedsExplicitRunAndTreeCanOpenWithoutExecuting() {
        var executions = 0
        var cancels = 0
        val target = AgentChatTarget("orch", "Fixture", OrchAIAgent("agent", "Reviewer", "Inspect"))
        val selection = AgentModelSelection("orch", "agent", "c", "openai", "exact-model", "head")
        val state = ChatUiState(selectedAgent = target, modelSelection = selection,
            pendingPlan = AgentPlan("Inspect devices", emptyList()), pendingPlanMessage = "Review first",
            agentRun = graph(1).copy(phase = "awaiting_approval"))
        compose.setContent { HydraTheme { ChatContent(state, {}, { executions++ }, { cancels++ }, {}) } }
        compose.onNodeWithTag("chat-default-agent").assertIsNotEnabled()
        compose.onNodeWithTag("chat-input").assertIsNotEnabled()
        compose.onNodeWithTag("chat-expand-agent-tree").performClick()
        compose.onNodeWithTag("agent-tree-dialog").assertIsDisplayed()
        assertEquals(0, executions)
        compose.onNodeWithTag("agent-tree-close").performClick()
        compose.onNodeWithTag("chat-run-plan").performScrollTo().performClick()
        assertEquals(1, executions)
        assertEquals(0, cancels)
    }

    private fun graph(active: Int): AgentRunSnapshot {
        val nodes = mutableListOf(AgentRunNode("root", kind = "root", title = "Task", status = "running", order = 0),
            AgentRunNode("agent", "root", "agent", "Reviewer", "running", 20))
        repeat(10) { index -> nodes += AgentRunNode("action-$index", "agent", "action", "Action $index",
            if (index == active) "running" else if (index < active) "completed" else "queued", 40 + index) }
        val edges = mutableListOf(AgentRunEdge("root", "agent", "delegation"))
        repeat(10) { index ->
            edges += AgentRunEdge("agent", "action-$index", "delegation")
            if (index > 0) edges += AgentRunEdge("action-${index - 1}", "action-$index", "sequence")
        }
        return AgentRunSnapshot("fixture-run", "executing", nodes = nodes, edges = edges)
    }
}
