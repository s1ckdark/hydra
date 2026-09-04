package com.hydra.android.feature.terminal

import android.app.Activity
import android.view.ViewGroup
import android.view.WindowManager
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
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
    val session by viewModel.session.collectAsStateWithLifecycle()

    LaunchedEffect(deviceId) { viewModel.connect(deviceId) }

    // A terminal session must outlive the screen timeout: the shell is still
    // attached even while nobody is typing. On this hardware it also keeps the
    // connect off the little cores — an idle screen throttles background
    // threads hard enough to stall the SSH key exchange for tens of seconds.
    KeepScreenOn()

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
                        // Required before anything else: TerminalView creates its
                        // renderer only inside setTextSize (TerminalView.java:515),
                        // and updateSize() dereferences it. Without this the view
                        // never sizes, the emulator is never created, and the shell
                        // never opens — a black screen with no error.
                        setTextSize(DEFAULT_TEXT_SIZE)
                        // Termux's default color scheme is light-on-dark, and the
                        // renderer only paints cells that have content — the rest
                        // shows through to the view background. Without an opaque
                        // dark background the white text lands on Compose's light
                        // surface and is invisible.
                        setBackgroundColor(android.graphics.Color.BLACK)
                        isFocusable = true
                        isFocusableInTouchMode = true
                        viewHolder.value = this
                    }
                },
                update = { view ->
                    // Runs whenever `session` changes, because it is collected
                    // state. attachSession is idempotent on the same instance,
                    // and internally calls updateSize() — which is what creates
                    // the emulator and lets the shell open.
                    session?.let { view.attachSession(it) }
                },
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(TERMINAL_VIEW_TAG),
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

private const val DEFAULT_TEXT_SIZE = 28

/** Lets an instrumented test capture just the terminal surface. */
const val TERMINAL_VIEW_TAG = "terminal-view"

/** Holds the window's screen-on flag for as long as this composable is present. */
@Composable
private fun KeepScreenOn() {
    val view = LocalView.current
    DisposableEffect(view) {
        val window = (view.context as? Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
}
