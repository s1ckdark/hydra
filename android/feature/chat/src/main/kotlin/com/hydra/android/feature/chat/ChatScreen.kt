package com.hydra.android.feature.chat

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.AgentTree
import com.hydra.android.core.designsystem.agentPhaseLabel
import com.hydra.android.core.designsystem.agentStatusLabel
import com.hydra.android.core.model.AgentModelSelection

@Composable
fun ChatScreen(viewModel: ChatViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    ChatContent(state, viewModel::send, viewModel::runPendingPlan, viewModel::cancelPendingPlan,
        onDefaultChat = { viewModel.selectAgent(null) })
}

/** Stateless entry point for previews and device tests; no server or preferences are read here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatContent(
    state: ChatUiState,
    onSend: (String) -> Unit,
    onRun: () -> Unit,
    onCancel: () -> Unit,
    onDefaultChat: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var draft by rememberSaveable(state.selectedAgent?.orchestrationId, state.selectedAgent?.agent?.id) { mutableStateOf("") }
    var showTree by rememberSaveable { mutableStateOf(false) }
    val listState = rememberLazyListState()
    LaunchedEffect(state.turns.size, state.pendingPlan != null) {
        val last = listState.layoutInfo.totalItemsCount - 1
        if (last >= 0) listState.animateScrollToItem(last)
    }
    Scaffold(
        modifier = modifier.testTag("chat-screen"),
        topBar = {
            TopAppBar(title = {
                Text(state.selectedAgent?.agent?.name ?: stringResource(R.string.chat_title),
                    Modifier.testTag("chat-active-agent"), maxLines = 1, overflow = TextOverflow.Ellipsis)
            })
        },
        bottomBar = {
            Row(Modifier.fillMaxWidth().imePadding().padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
                OutlinedTextField(value = draft, onValueChange = { draft = it }, enabled = state.canSend,
                    placeholder = { Text(stringResource(R.string.chat_input_hint)) }, maxLines = 5,
                    modifier = Modifier.weight(1f).testTag("chat-input"))
                FilledIconButton(
                    onClick = { if (state.canSend && draft.isNotBlank()) { onSend(draft); draft = "" } },
                    enabled = draft.isNotBlank() && state.canSend,
                    modifier = Modifier.testTag("chat-send"),
                ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.chat_send)) }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            state.selectedAgent?.let { target ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(target.orchestrationName, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (state.modelSelection != null) {
                        ModelSelectionLabel(state.modelSelection, Modifier.testTag("chat-active-model"))
                    } else if (target.modelLabel != null) {
                        Text(target.modelLabel!!, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                        Text(stringResource(R.string.chat_fixed_model), style = MaterialTheme.typography.labelSmall)
                    } else {
                        Text(stringResource(R.string.chat_head_will_choose), style = MaterialTheme.typography.bodySmall)
                    }
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = onDefaultChat, enabled = state.canSwitchAgent, modifier = Modifier.testTag("chat-default-agent")) {
                            Text(stringResource(R.string.chat_default))
                        }
                        if (!state.canSwitchAgent) Text(stringResource(R.string.chat_switch_blocked),
                            style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f))
                    }
                }
            }
            if (state.agentRun != null || state.progressDisconnected || state.progressUnavailable) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp).testTag("chat-agent-tree-summary")) {
                    state.agentRun?.let { run ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(agentPhaseLabel(run.phase), style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f))
                            TextButton(onClick = { showTree = true }, modifier = Modifier.testTag("chat-expand-agent-tree")) {
                                Text(stringResource(R.string.chat_expand_tree))
                            }
                        }
                        run.activeNodes.forEach { node ->
                            Text("${node.title} · ${agentStatusLabel(node.status)}", style = MaterialTheme.typography.bodySmall, maxLines = 1)
                        }
                    }
                    if (state.progressDisconnected) Text(stringResource(R.string.chat_disconnected),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    else if (state.progressUnavailable) Text(stringResource(R.string.chat_progress_unavailable), style = MaterialTheme.typography.bodySmall)
                }
            }
            LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxWidth().testTag("chat-history"),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (state.turns.isEmpty() && state.pendingPlan == null) {
                    item("empty") {
                        Column(Modifier.fillMaxWidth().padding(vertical = 36.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(stringResource(R.string.chat_empty_title), style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(R.string.chat_empty_hint), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                items(state.turns, key = { it.id }) { ChatTurnRow(it) }
                state.pendingPlan?.let { plan ->
                    item("pendingPlan") { PlanCard(plan, state.pendingPlanMessage, state.isThinking, onRun, onCancel) }
                }
                state.error?.let { error -> item("error") {
                    Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("chat-error"))
                } }
                if (state.isThinking) item("thinking") {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text(stringResource(R.string.chat_processing), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
    if (showTree) {
        Dialog(onDismissRequest = { showTree = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Scaffold(modifier = Modifier.fillMaxSize().testTag("agent-tree-dialog"), topBar = {
                TopAppBar(title = { Text(stringResource(R.string.chat_tree_title)) }, navigationIcon = {
                    IconButton(onClick = { showTree = false }, modifier = Modifier.testTag("agent-tree-close")) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.chat_close))
                    }
                })
            }) { padding ->
                Column(Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(12.dp)) {
                    state.agentRun?.let { AgentTree(it, state.progressDisconnected || state.progressUnavailable) }
                }
            }
        }
    }
}

@Composable
internal fun ModelSelectionLabel(selection: AgentModelSelection, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text("${selection.provider} · ${selection.model}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        Text(stringResource(if (selection.source == "override") R.string.chat_fixed_model else R.string.chat_head_selected),
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
