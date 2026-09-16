package com.hydra.android.feature.tasks

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.HydraBlue
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.HydraGreen
import com.hydra.android.core.designsystem.HydraOrange
import com.hydra.android.core.model.SavedTask
import com.hydra.android.core.model.TaskPriority
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

@Composable
internal fun priorityTint(priority: TaskPriority): Color = when (priority) {
    TaskPriority.LOW -> MaterialTheme.colorScheme.onSurfaceVariant
    TaskPriority.NORMAL -> HydraBlue
    TaskPriority.HIGH -> HydraOrange
    TaskPriority.URGENT -> MaterialTheme.colorScheme.error
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun TasksScreen(
    onOpenEditor: (String?) -> Unit,
    viewModel: TasksViewModel = hiltViewModel(),
) {
    val tasks by viewModel.tasks.collectAsStateWithLifecycle()
    val runtime by viewModel.runtime.collectAsStateWithLifecycle()
    var pendingDelete by remember { mutableStateOf<SavedTask?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Tasks") },
                actions = {
                    IconButton(onClick = { onOpenEditor(null) }) {
                        Icon(Icons.Filled.Add, contentDescription = "새 태스크")
                    }
                },
            )
        }
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (tasks.isEmpty()) {
                Column(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("저장된 태스크가 없습니다", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "+ 로 명령 템플릿을 만들어 두세요",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    runtime.error?.let { error ->
                        item {
                            Text(
                                error,
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    items(tasks, key = { it.id }) { task ->
                        TaskRow(
                            task = task,
                            isRunning = task.id in runtime.runningIds,
                            output = runtime.lastOutputs[task.id],
                            onOpen = { onOpenEditor(task.id) },
                            onLongPress = { pendingDelete = task },
                            onRun = { viewModel.run(task.id) },
                        )
                    }
                }
            }
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("태스크를 삭제할까요?") },
            text = { Text(target.name) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.delete(target.id)
                    pendingDelete = null
                }) { Text("삭제", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("취소") }
            },
        )
    }

    runtime.needsTargetForTaskId?.let { taskId ->
        AlertDialog(
            onDismissRequest = viewModel::dismissTargetPrompt,
            title = { Text("어느 기기에서 실행할까요?") },
            text = {
                Column {
                    runtime.devices.forEach { device ->
                        Text(
                            device.shortName,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { viewModel.runOnDevice(taskId, device.id) }
                                .padding(vertical = 10.dp),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = viewModel::dismissTargetPrompt) { Text("취소") }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TaskRow(
    task: SavedTask,
    isRunning: Boolean,
    output: String?,
    onOpen: () -> Unit,
    onLongPress: () -> Unit,
    onRun: () -> Unit,
) {
    var showOutput by remember { mutableStateOf(false) }

    HydraCard(
        Modifier.combinedClickable(onClick = onOpen, onLongClick = onLongPress)
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(Modifier.weight(1f)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(task.name, style = MaterialTheme.typography.titleSmall)
                    val tint = priorityTint(task.priority)
                    Text(
                        task.priority.name.lowercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = tint,
                        modifier = Modifier
                            .background(tint.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 6.dp, vertical = 1.dp),
                    )
                }
                Text(
                    task.command,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    task.targetDeviceName ?: task.targetDeviceId ?: "실행 시 선택",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                task.lastRunStatus?.let { status ->
                    Text(
                        lastRunLabel(status, task.lastRunAt),
                        style = MaterialTheme.typography.labelSmall,
                        color = if (status == "success") {
                            HydraGreen
                        } else {
                            MaterialTheme.colorScheme.error
                        },
                    )
                }
            }

            // Run is an explicit button, not a hidden swipe: iOS puts it behind
            // a leading swipe, which nobody discovers on Android.
            if (isRunning) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                IconButton(onClick = onRun) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = "실행")
                }
            }
        }

        output?.takeIf { it.isNotBlank() }?.let { text ->
            TextButton(onClick = { showOutput = !showOutput }) {
                Text(if (showOutput) "출력 숨기기" else "출력 보기")
            }
            if (showOutput) {
                Text(
                    // Ten lines is enough to see whether the command did what
                    // was expected without turning a list row into a log viewer.
                    text.lineSequence().take(10).joinToString("\n"),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

/**
 * "success · 09-04 14:44". The raw Instant reads as a UTC machine
 * timestamp, which is not what someone glancing at a task row wants.
 */
internal fun lastRunLabel(
    status: String,
    at: Instant?,
    zone: TimeZone = TimeZone.currentSystemDefault(),
): String {
    val local = at?.toLocalDateTime(zone) ?: return status
    fun pad(value: Int) = value.toString().padStart(2, '0')
    return "$status · ${pad(local.monthNumber)}-${pad(local.dayOfMonth)} " +
        "${pad(local.hour)}:${pad(local.minute)}"
}
