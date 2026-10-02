package com.hydra.android.core.designsystem

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.hydra.android.core.model.AgentRunNode
import com.hydra.android.core.model.AgentRunSnapshot
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Shared live graph. Every card and arrow is backed by the received run snapshot. */
@Composable
fun AgentTree(snapshot: AgentRunSnapshot, disconnected: Boolean, modifier: Modifier = Modifier) {
    val vertical = rememberScrollState()
    val horizontal = rememberScrollState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    var selectedId by remember(snapshot.runId) { mutableStateOf<String?>(null) }
    BoxWithConstraints(modifier.fillMaxWidth().testTag("agent-tree")) {
        val layout = remember(snapshot, maxWidth) { AgentTreeLayout.calculate(snapshot, maxWidth.value) }
        val current = snapshot.activeNodes.lastOrNull()
        val nodeMap = remember(snapshot) { snapshot.nodes.associateBy { it.id } }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.AccountTree, contentDescription = null, modifier = Modifier.size(20.dp))
                Text(stringResource(R.string.agent_tree_title), Modifier.padding(start = 6.dp).weight(1f), style = MaterialTheme.typography.titleSmall)
                if (current != null) {
                    TextButton(
                        modifier = Modifier.testTag("agent-tree-current-step"),
                        onClick = {
                            val frame = layout.nodes.firstOrNull { it.id == current.id }?.frame ?: return@TextButton
                            scope.launch {
                                val x = with(density) { frame.centerX.dp.toPx() } - viewport.width / 2
                                val y = with(density) { frame.centerY.dp.toPx() } - viewport.height / 2
                                horizontal.scrollTo(x.roundToInt().coerceIn(0, horizontal.maxValue))
                                vertical.scrollTo(y.roundToInt().coerceIn(0, vertical.maxValue))
                            }
                        },
                    ) {
                        Icon(Icons.Default.MyLocation, contentDescription = null, modifier = Modifier.size(16.dp))
                        Text(stringResource(R.string.agent_tree_current_step), Modifier.padding(start = 4.dp))
                    }
                }
            }
            Text(agentPhaseLabel(snapshot.phase), style = MaterialTheme.typography.labelMedium, modifier = Modifier.testTag("agent-tree-phase"))
            if (disconnected) {
                Text(stringResource(R.string.agent_tree_disconnected), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Text(stringResource(R.string.agent_tree_direction), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (snapshot.nodes.isEmpty()) {
                Text(stringResource(R.string.agent_tree_empty), Modifier.padding(24.dp))
            } else {
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 280.dp, max = 480.dp)
                        .onSizeChanged { viewport = it }
                        .testTag("agent-tree-scroll")
                        .verticalScroll(vertical).horizontalScroll(horizontal),
                ) {
                    Box(Modifier.width(layout.width.dp).height(layout.height.dp)) {
                        layout.branches.forEach { branch ->
                            Box(Modifier.offset(branch.frame.left.dp, branch.frame.top.dp)
                                .size(branch.frame.width.dp, branch.frame.height.dp)
                                .background(MaterialTheme.colorScheme.primary.copy(alpha = .035f), MaterialTheme.shapes.medium))
                        }
                        val lineColor = MaterialTheme.colorScheme.outline
                        Canvas(Modifier.matchParentSize().clearAndSetSemantics {}) {
                            layout.connectors.forEach { connector ->
                                val points = connector.points.map { Offset(it.x.dp.toPx(), it.y.dp.toPx()) }
                                val path = Path().apply {
                                    moveTo(points.first().x, points.first().y)
                                    points.drop(1).forEach { lineTo(it.x, it.y) }
                                }
                                drawPath(path, lineColor, style = Stroke(1.5.dp.toPx(),
                                    pathEffect = if (connector.edge.kind == "delegation") PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx())) else null))
                                val end = points.last()
                                drawLine(lineColor, Offset(end.x - 5.dp.toPx(), end.y - 7.dp.toPx()), end, 1.5.dp.toPx())
                                drawLine(lineColor, Offset(end.x + 5.dp.toPx(), end.y - 7.dp.toPx()), end, 1.5.dp.toPx())
                            }
                        }
                        layout.nodes.forEach { placed ->
                            nodeMap[placed.id]?.let { node ->
                                AgentNodeCard(node, placed.step, selectedId == node.id, { selectedId = node.id },
                                    Modifier.offset(placed.frame.left.dp, placed.frame.top.dp).size(placed.frame.width.dp, placed.frame.height.dp))
                            }
                        }
                    }
                }
            }
            selectedId?.let(nodeMap::get)?.let { node ->
                Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.fillMaxWidth().testTag("agent-tree-node-details")) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(agentNodeTitle(node), style = MaterialTheme.typography.titleSmall)
                        Text(agentStatusLabel(node.status), style = MaterialTheme.typography.labelMedium)
                        node.message?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        if (node.startedAt != null && node.finishedAt != null) {
                            val seconds = (node.finishedAt!!.toEpochMilliseconds() - node.startedAt!!.toEpochMilliseconds()).coerceAtLeast(0) / 1000.0
                            Text(stringResource(R.string.agent_tree_duration, seconds), style = MaterialTheme.typography.bodySmall)
                        }
                        node.actionType?.let { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
                    }
                }
            }
        }
    }
}

@Composable
private fun AgentNodeCard(node: AgentRunNode, step: Int?, selected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val color = when (node.status) {
        "running" -> MaterialTheme.colorScheme.primary
        "failed", "unknown" -> MaterialTheme.colorScheme.error
        "waiting" -> MaterialTheme.colorScheme.tertiary
        "completed" -> HydraGreen
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Card(onClick = onClick, modifier = modifier.testTag("agent-tree-node-${node.id}"),
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(if (selected || node.status == "running") 2.dp else 1.dp,
            if (selected || node.status == "running") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(if (step == null) stringResource(R.string.agent_tree_task) else stringResource(R.string.agent_tree_step, step),
                    style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f))
                if (node.status == "running") CircularProgressIndicator(Modifier.size(14.dp).clearAndSetSemantics {}, strokeWidth = 2.dp)
                Text(agentStatusLabel(node.status), color = color, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(start = 4.dp))
            }
            Text(agentNodeTitle(node), style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
            node.model?.takeIf { it.isNotBlank() }?.let {
                Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            (node.provider ?: node.actionType)?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
        }
    }
}

@Composable
fun agentStatusLabel(status: String): String = stringResource(when (status) {
    "queued" -> R.string.agent_status_queued
    "running" -> R.string.agent_status_running
    "waiting" -> R.string.agent_status_waiting
    "completed" -> R.string.agent_status_completed
    "failed" -> R.string.agent_status_failed
    "skipped" -> R.string.agent_status_skipped
    "cancelled" -> R.string.agent_status_cancelled
    else -> R.string.agent_status_unknown
})

@Composable
fun agentPhaseLabel(phase: String): String = when (phase) {
    "planning" -> stringResource(R.string.agent_phase_planning)
    "executing" -> stringResource(R.string.agent_phase_executing)
    "awaiting_approval" -> agentStatusLabel("waiting")
    else -> agentStatusLabel(phase)
}

@Composable
private fun agentNodeTitle(node: AgentRunNode): String = when (node.kind) {
    "root" -> stringResource(R.string.agent_tree_orchestration)
    "head" -> stringResource(R.string.agent_tree_head)
    "approval" -> stringResource(R.string.agent_tree_approval)
    "summary" -> stringResource(R.string.agent_tree_summary)
    "action" -> when (node.actionType) {
        "list_devices" -> stringResource(R.string.agent_action_devices)
        "list_orchs" -> stringResource(R.string.agent_action_orchs)
        "get_metrics" -> stringResource(R.string.agent_action_metrics)
        "get_gpu" -> stringResource(R.string.agent_action_gpu)
        "recent_tasks" -> stringResource(R.string.agent_action_tasks)
        "create_orch" -> stringResource(R.string.agent_action_create)
        "delete_orch" -> stringResource(R.string.agent_action_delete)
        "execute_command" -> stringResource(R.string.agent_action_execute)
        else -> node.title
    }
    else -> node.title
}
