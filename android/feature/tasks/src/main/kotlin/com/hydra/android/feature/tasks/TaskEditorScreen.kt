package com.hydra.android.feature.tasks

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.model.SavedTask
import com.hydra.android.core.model.TaskPriority
import kotlinx.datetime.Clock
import java.util.UUID

private const val DEFAULT_TIMEOUT = 30

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskEditorScreen(
    taskId: String?,
    onDone: () -> Unit,
    onBack: () -> Unit,
    viewModel: TasksViewModel = hiltViewModel(),
) {
    val tasks by viewModel.tasks.collectAsStateWithLifecycle()
    val runtime by viewModel.runtime.collectAsStateWithLifecycle()
    val existing = tasks.firstOrNull { it.id == taskId }

    // Screen-owned buffers: binding a field's value to ViewModel state loses
    // keystrokes on fast input.
    var name by rememberSaveable { mutableStateOf("") }
    var command by rememberSaveable { mutableStateOf("") }
    var target by rememberSaveable { mutableStateOf<String?>(null) }
    var timeout by rememberSaveable { mutableStateOf(DEFAULT_TIMEOUT.toString()) }
    var priority by rememberSaveable { mutableStateOf(TaskPriority.NORMAL) }
    var seeded by rememberSaveable { mutableStateOf(false) }

    // Seed once: the store emits again after every save, and re-seeding would
    // overwrite whatever the user is typing.
    LaunchedEffect(existing) {
        val task = existing
        if (task != null && !seeded) {
            name = task.name
            command = task.command
            target = task.targetDeviceId
            timeout = task.timeout.toString()
            priority = task.priority
            seeded = true
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (taskId == null) "새 태스크" else "태스크 편집") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "뒤로")
                    }
                },
                actions = {
                    TextButton(
                        onClick = {
                            viewModel.save(
                                SavedTask(
                                    id = existing?.id ?: UUID.randomUUID().toString(),
                                    name = name.trim(),
                                    command = command.trim(),
                                    targetDeviceId = target,
                                    targetDeviceName = runtime.devices
                                        .firstOrNull { it.id == target }?.shortName,
                                    // The server clamps to 1-300; anything
                                    // unparseable just falls back to the default.
                                    timeout = timeout.toIntOrNull()
                                        ?.takeIf { it in 1..300 } ?: DEFAULT_TIMEOUT,
                                    priority = priority,
                                    lastRunAt = existing?.lastRunAt,
                                    lastRunStatus = existing?.lastRunStatus,
                                    createdAt = existing?.createdAt ?: Clock.System.now(),
                                )
                            )
                            onDone()
                        },
                        enabled = name.isNotBlank() && command.isNotBlank(),
                    ) { Text("저장") }
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
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("이름") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = command,
                onValueChange = { command = it },
                label = { Text("명령") },
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = FontFamily.Monospace,
                ),
                minLines = 3,
                modifier = Modifier.fillMaxWidth(),
            )

            Text("실행 대상", style = MaterialTheme.typography.titleSmall)
            TargetRow(
                label = "실행 시 선택",
                selected = target == null,
                onSelect = { target = null },
            )
            runtime.devices.forEach { device ->
                TargetRow(
                    label = device.shortName,
                    selected = target == device.id,
                    onSelect = { target = device.id },
                )
            }

            OutlinedTextField(
                value = timeout,
                onValueChange = { timeout = it },
                label = { Text("타임아웃(초)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )

            Text("우선순위", style = MaterialTheme.typography.titleSmall)
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TaskPriority.entries.forEach { value ->
                    FilterChip(
                        selected = priority == value,
                        onClick = { priority = value },
                        label = { Text(value.name.lowercase()) },
                    )
                }
            }
        }
    }
}

@Composable
private fun TargetRow(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Text(label, style = MaterialTheme.typography.bodyMedium)
    }
}
