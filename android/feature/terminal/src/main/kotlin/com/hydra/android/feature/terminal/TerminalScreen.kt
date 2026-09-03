package com.hydra.android.feature.terminal

import android.view.ViewGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.termux.view.TerminalView

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    deviceId: String,
    onClose: () -> Unit,
    viewModel: TerminalViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(deviceId) { viewModel.connect(deviceId) }

    // Held so the view client can call back into the view it is attached to.
    val viewHolder = remember { mutableStateOf<TerminalView?>(null) }
    val client = remember { HydraTerminalViewClient { viewHolder.value } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(state.deviceName.ifEmpty { "터미널" }) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.Filled.Close, contentDescription = "닫기")
                    }
                },
            )
        }
    ) { padding ->
        Box(
            Modifier
                .padding(padding)
                .fillMaxSize()
        ) {
            AndroidView(
                factory = { ctx ->
                    TerminalView(ctx, null).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        setTerminalViewClient(client)
                        isFocusable = true
                        isFocusableInTouchMode = true
                        viewHolder.value = this
                    }
                },
                update = { view ->
                    // The session only exists once connect() has resolved the
                    // device; attaching is idempotent (attachSession no-ops on
                    // the same instance).
                    viewModel.session?.let { view.attachSession(it) }
                },
                modifier = Modifier.fillMaxSize(),
            )

            state.error?.let { error ->
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth(),
                ) {
                    Text(
                        error,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(12.dp),
                    )
                }
            }
        }
    }

    state.pendingHostKey?.let { fingerprint ->
        AlertDialog(
            onDismissRequest = viewModel::rejectHostKey,
            title = { Text("호스트 키를 신뢰할까요?") },
            text = { Text(fingerprint.sha256) },
            confirmButton = {
                TextButton(onClick = viewModel::acceptHostKey) { Text("신뢰") }
            },
            dismissButton = {
                TextButton(onClick = viewModel::rejectHostKey) { Text("취소") }
            },
        )
    }
}
