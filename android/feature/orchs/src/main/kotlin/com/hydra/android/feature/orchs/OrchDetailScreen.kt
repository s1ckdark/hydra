package com.hydra.android.feature.orchs

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.AgentTree
import com.hydra.android.core.designsystem.HydraPurple
import com.hydra.android.core.designsystem.StatusDot
import com.hydra.android.core.model.WorkerProcess
import com.hydra.android.core.model.WorkerStatus
import com.hydra.android.core.model.AgentChatTarget
import com.hydra.android.core.model.AgentRunSnapshot

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrchDetailScreen(
    orchId: String,
    onBack: () -> Unit,
    viewModel: OrchDetailViewModel = hiltViewModel(),
    onOpenAgentChat: (AgentChatTarget) -> Unit = {},
    canSwitchAgent: Boolean = true,
    agentRun: AgentRunSnapshot? = null,
    runOrchestrationId: String? = null,
    progressDisconnected: Boolean = false,
    progressUnavailable: Boolean = false,
    agentsViewModel: OrchAgentsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val agentsState by agentsViewModel.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable { mutableStateOf("") }
    var expandedTree by rememberSaveable(orchId) { mutableStateOf(false) }
    val orchestrationName = state.health?.name?.ifBlank { orchId } ?: orchId
    val matchingRun = agentRun?.takeIf { runOrchestrationId == orchId }

    DisposableEffect(orchId, agentsViewModel) {
        onDispose { agentsViewModel.cancelEditor() }
    }

    agentsState.draft?.takeIf { agentsState.orchId == orchId }?.let { configuration ->
        Dialog(
            onDismissRequest = { if (!agentsState.isSaving) agentsViewModel.cancelEditor() },
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                dismissOnBackPress = !agentsState.isSaving,
                dismissOnClickOutside = false,
            ),
        ) {
            OrchAgentsEditor(
                orchestrationName = orchestrationName,
                original = agentsState.configuration,
                draft = configuration,
                isSaving = agentsState.isSaving,
                saveError = agentsState.saveError,
                onDraftChange = agentsViewModel::updateDraft,
                onSave = agentsViewModel::save,
                onCancel = agentsViewModel::cancelEditor,
            )
        }
    }

    if (expandedTree && matchingRun != null) {
        Dialog(onDismissRequest = { expandedTree = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Scaffold(
                modifier = Modifier.fillMaxSize(),
                topBar = {
                    TopAppBar(title = { Text("Agent Tree") }, navigationIcon = {
                        TextButton(onClick = { expandedTree = false }) { Text("닫기") }
                    })
                },
            ) { padding ->
                Column(Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(16.dp)) {
                    AgentTree(matchingRun, progressDisconnected || progressUnavailable, Modifier.fillMaxWidth())
                }
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(state.health?.name?.ifEmpty { orchId } ?: orchId) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "뒤로")
                    }
                },
            )
        }
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            state.health?.let { health ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(health.status, color = orchStatusTint(health.status))
                }
            }

            state.error?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                InfoCard(Modifier.weight(1f), "Head Node", state.headNodeId ?: "-")
                InfoCard(Modifier.weight(1f), "Workers", "${state.workers.size}")
            }

            if (matchingRun != null) {
                HydraCard {
                    TextButton(onClick = { expandedTree = true }) { Text("Agent Tree 크게 보기") }
                    AgentTree(
                        matchingRun, progressDisconnected || progressUnavailable,
                        Modifier.fillMaxWidth().heightIn(min = 180.dp),
                    )
                }
            }

            if (agentsState.orchId == orchId) {
                OrchAgentsCard(
                    orchestrationId = orchId,
                    orchestrationName = orchestrationName,
                    state = agentsState,
                    canSwitchAgent = canSwitchAgent,
                    onConfigure = agentsViewModel::edit,
                    onRetry = agentsViewModel::reload,
                    onOpenAgentChat = onOpenAgentChat,
                )
            }

            state.health?.let { health ->
                HydraCard {
                    Text("노드 상태", style = MaterialTheme.typography.titleSmall)
                    health.nodes.forEach { node ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(top = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            StatusDot(node.healthy)
                            Text(
                                node.nodeId,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                            )
                            Text(
                                node.role,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            node.error?.takeIf { it.isNotEmpty() }?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                    }
                }
            }

            HydraCard {
                Text("명령 실행", style = MaterialTheme.typography.titleSmall)
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text("uptime") },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp),
                )
                Row(
                    Modifier.padding(top = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Button(
                        onClick = { viewModel.execute(draft) },
                        enabled = draft.isNotBlank() && !state.isExecuting,
                    ) { Text("실행") }
                    if (state.isExecuting) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    }
                }
                state.executeResult?.results?.forEach { result ->
                    Column(Modifier.padding(top = 8.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                result.deviceName.ifEmpty { result.deviceId },
                                style = MaterialTheme.typography.labelMedium,
                            )
                            Text(
                                "%.0fms".format(result.durationMs),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        if (result.hasError) {
                            Text(
                                result.error.orEmpty(),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.error,
                            )
                        } else {
                            Text(
                                result.output,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 6,
                            )
                        }
                    }
                }
            }

            HydraCard {
                Text("워커 프로세스", style = MaterialTheme.typography.titleSmall)
                if (state.workers.isEmpty()) {
                    Text(
                        "표시할 워커가 없습니다",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
                state.workers.forEach { worker -> WorkerBlock(worker) }
            }
        }
    }
}

@Composable
private fun InfoCard(modifier: Modifier, label: String, value: String) {
    HydraCard(modifier) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(value, style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
private fun WorkerBlock(worker: WorkerStatus) {
    Column(Modifier.padding(top = 8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(worker.shortName, style = MaterialTheme.typography.labelMedium)
            worker.gpu?.takeIf { it.isNotEmpty() }?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.labelSmall,
                    color = HydraPurple,
                )
            }
        }
        // A worker that failed to report shows why instead of an empty list.
        if (worker.hasError) {
            Text(
                worker.error.orEmpty(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.error,
            )
            return@Column
        }
        worker.processes.forEach { process ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    processLabel(process),
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(0.4f),
                )
                Text(
                    "PID ${process.pid}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(0.25f),
                )
                Text(
                    "%.0f%%".format(process.cpuPercent),
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.weight(0.15f),
                )
                Text(
                    if (process.vramMB > 0) "${process.vramMB}MB" else "",
                    style = MaterialTheme.typography.labelSmall,
                    color = HydraPurple,
                    modifier = Modifier.weight(0.2f),
                )
            }
        }
    }
}

/**
 * handler.go leaves processName empty and puts the real thing in command,
 * which is what iOS renders too. The pid is the last resort so a row is never
 * blank.
 */
internal fun processLabel(process: WorkerProcess): String =
    process.processName.ifBlank { process.command }.ifBlank { "PID ${process.pid}" }
