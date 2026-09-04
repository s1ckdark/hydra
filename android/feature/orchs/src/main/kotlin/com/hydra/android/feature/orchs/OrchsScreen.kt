package com.hydra.android.feature.orchs

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
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
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.HydraGreen
import com.hydra.android.core.designsystem.HydraOrange
import com.hydra.android.core.model.Orch

/** Status tint mapping, matching iOS `OrchRow.statusColor`. */
@Composable
internal fun orchStatusTint(status: String): Color = when (status) {
    "running" -> HydraGreen
    "starting" -> HydraOrange
    "error" -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun OrchsScreen(
    onOpenDetail: (String) -> Unit,
    onOpenCreate: () -> Unit,
    viewModel: OrchsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var pendingDelete by remember { mutableStateOf<Orch?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Orchs") },
                actions = {
                    IconButton(onClick = onOpenCreate) {
                        Icon(Icons.Filled.Add, contentDescription = "새 Orchestration")
                    }
                },
            )
        }
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isLoading && state.orchs.isNotEmpty(),
            onRefresh = viewModel::refresh,
            modifier = Modifier.padding(padding),
        ) {
            LazyColumn(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                state.error?.let { error ->
                    item {
                        Text(
                            error,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                items(state.orchs, key = { it.id }) { orch ->
                    OrchRow(
                        orch = orch,
                        onClick = { onOpenDetail(orch.id) },
                        onLongClick = { pendingDelete = orch },
                    )
                }
            }

            if (state.isLoading && state.orchs.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Orch을 삭제할까요?") },
            text = { Text("${target.name} — 되돌릴 수 없습니다.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.delete(target.id)
                    pendingDelete = null
                }) {
                    Text("삭제", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("취소") }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun OrchRow(orch: Orch, onClick: () -> Unit, onLongClick: () -> Unit) {
    HydraCard(
        // Long-press to delete is the Android idiom where iOS swipes, and the
        // confirmation is warranted: the delete is forced and irreversible.
        Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick)
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column {
                Text(orch.name, style = MaterialTheme.typography.titleSmall)
                Text(
                    "${orch.workerCount} workers",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            val tint = orchStatusTint(orch.status)
            Text(
                orch.status,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = tint,
                modifier = Modifier
                    .background(tint.copy(alpha = 0.12f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
    }
}
