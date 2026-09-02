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
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
fun SettingsScreen(viewModel: SettingsViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()

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
                value = state.serverUrl,
                onValueChange = viewModel::onServerUrlChange,
                label = { Text("http://<host>:8080") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    capitalization = KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.apiKey,
                onValueChange = viewModel::onApiKeyChange,
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
                value = state.aiInstruction,
                onValueChange = viewModel::onAiInstructionChange,
                label = { Text("AI에게 전달할 지침") },
                minLines = 3,
                maxLines = 8,
                modifier = Modifier.fillMaxWidth(),
            )

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
