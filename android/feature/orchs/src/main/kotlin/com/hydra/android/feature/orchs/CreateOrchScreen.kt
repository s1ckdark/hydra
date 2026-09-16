package com.hydra.android.feature.orchs

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.HydraPurple

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreateOrchScreen(
    onDone: () -> Unit,
    onBack: () -> Unit,
    viewModel: CreateOrchViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    // Screen-owned buffer, as everywhere else in this app: binding a field's
    // value straight to ViewModel state loses keystrokes on fast input.
    var name by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(state.created) { if (state.created) onDone() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("새 Orchestration") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "뒤로")
                    }
                },
                actions = {
                    TextButton(onClick = viewModel::create, enabled = state.canCreate) {
                        Text("생성")
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
            OutlinedTextField(
                value = name,
                onValueChange = {
                    name = it
                    viewModel.onNameChange(it)
                },
                label = { Text("이름") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Text("코디네이터", style = MaterialTheme.typography.titleSmall)
            state.devices.forEach { device ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { viewModel.onCoordinatorChange(device.id) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(
                        selected = state.coordinatorId == device.id,
                        onClick = { viewModel.onCoordinatorChange(device.id) },
                    )
                    Column {
                        Text(device.shortName, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            device.tailscaleIp.ifEmpty { device.hostname },
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            Text("워커", style = MaterialTheme.typography.titleSmall)
            state.devices.filter { it.id != state.coordinatorId }.forEach { device ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { viewModel.toggleWorker(device.id) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(
                        checked = device.id in state.selectedWorkers,
                        onCheckedChange = { viewModel.toggleWorker(device.id) },
                    )
                    Text(device.shortName, style = MaterialTheme.typography.bodyMedium)
                    if (device.hasGpu) {
                        Text(
                            "${device.gpuCount}x ${device.gpuModel.orEmpty()}",
                            style = MaterialTheme.typography.labelSmall,
                            color = HydraPurple,
                            modifier = Modifier.padding(start = 6.dp),
                        )
                    }
                }
            }

            state.error?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}
