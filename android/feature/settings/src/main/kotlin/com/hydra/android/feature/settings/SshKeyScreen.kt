package com.hydra.android.feature.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.HydraGreen

/**
 * Import-only. Key generation needs OpenSSH private-key serialization written
 * by hand; importing an existing key reaches a working terminal sooner.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SshKeyScreen(
    onBack: () -> Unit,
    viewModel: SshKeyViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current

    // The field owns its buffer; binding straight to state makes each keystroke
    // a round trip and loses characters on fast input (v1 hit this for real).
    var pem by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(state.pem) {
        if (pem == null && state.pem.isNotEmpty()) pem = state.pem
    }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val text = runCatching {
            context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        }.getOrNull()
        if (text != null) {
            pem = text
            viewModel.onPemChange(text)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("SSH 키") },
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
            Text(
                if (state.hasStoredKey) "키 저장됨 ✓" else "저장된 키 없음",
                style = MaterialTheme.typography.bodyMedium,
                color = if (state.hasStoredKey) {
                    HydraGreen
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )

            OutlinedTextField(
                value = pem.orEmpty(),
                onValueChange = {
                    pem = it
                    viewModel.onPemChange(it)
                },
                label = { Text("SSH 개인키 (PEM)") },
                textStyle = MaterialTheme.typography.bodySmall.copy(
                    fontFamily = FontFamily.Monospace,
                ),
                minLines = 8,
                modifier = Modifier.fillMaxWidth(),
            )

            TextButton(onClick = { picker.launch(arrayOf("*/*")) }) {
                Text("파일에서 가져오기")
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = viewModel::save) { Text("저장") }
                if (state.hasStoredKey) {
                    TextButton(onClick = {
                        viewModel.delete()
                        pem = ""
                    }) {
                        Text("삭제", color = MaterialTheme.colorScheme.error)
                    }
                }
            }

            state.message?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
