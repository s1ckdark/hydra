package com.hydra.android.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Mirrors HydraiOS/Screens/SettingsScreen.swift minus the SSH section — v1
 * has no SSH, and a settings row that controls nothing invites bug reports.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onOpenSshKey: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    // Each field owns its own buffer and notifies the ViewModel as a side
    // effect. Binding a TextField's `value` straight to state makes every
    // keystroke a round trip through the ViewModel's flow (and, before it was
    // fixed, through DataStore) — the field then renders a value one hop
    // behind, the next keystroke is computed from that stale text, and
    // characters silently vanish when someone types quickly.
    var serverUrl by rememberSaveable { mutableStateOf<String?>(null) }
    var apiKey by rememberSaveable { mutableStateOf<String?>(null) }
    var aiInstruction by rememberSaveable { mutableStateOf<String?>(null) }
    var sshUsername by rememberSaveable { mutableStateOf<String?>(null) }

    // Adopt the stored values once they arrive, and never again — re-adopting
    // would fight the user's typing.
    LaunchedEffect(state.serverUrl) {
        if (serverUrl == null && state.serverUrl.isNotEmpty()) serverUrl = state.serverUrl
    }
    LaunchedEffect(state.apiKey) {
        if (apiKey == null && state.apiKey.isNotEmpty()) apiKey = state.apiKey
    }
    LaunchedEffect(state.aiInstruction) {
        if (aiInstruction == null && state.aiInstruction.isNotEmpty()) {
            aiInstruction = state.aiInstruction
        }
    }
    LaunchedEffect(state.sshUsername) {
        if (sshUsername == null && state.sshUsername.isNotEmpty()) sshUsername = state.sshUsername
    }

    Scaffold(topBar = { TopAppBar(title = { Text("설정") }) }) { padding ->
        Column(
            Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("서버", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                value = serverUrl.orEmpty(),
                onValueChange = {
                    serverUrl = it
                    viewModel.onServerUrlChange(it)
                },
                label = { Text("http://<host>:8080") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    capitalization = KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = apiKey.orEmpty(),
                onValueChange = {
                    apiKey = it
                    viewModel.onApiKeyChange(it)
                },
                label = { Text("API 키") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    capitalization = KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            HorizontalDivider()

            Text("AI", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                value = aiInstruction.orEmpty(),
                onValueChange = {
                    aiInstruction = it
                    viewModel.onAiInstructionChange(it)
                },
                label = { Text("AI에게 전달할 지침") },
                minLines = 3,
                maxLines = 8,
                modifier = Modifier.fillMaxWidth(),
            )

            HorizontalDivider()

            Text("SSH", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                value = sshUsername.orEmpty(),
                onValueChange = {
                    sshUsername = it
                    viewModel.onSshUsernameChange(it)
                },
                label = { Text("username") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Text,
                    capitalization = KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            TextButton(onClick = onOpenSshKey) { Text("SSH 키 관리") }

            HorizontalDivider()

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("모바일 디바이스 숨기기")
                Switch(
                    checked = state.hideMobileDevices,
                    onCheckedChange = viewModel::onHideMobileChange,
                )
            }
        }
    }
}
