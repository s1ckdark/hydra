package com.hydra.android.feature.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.feature.dashboard.sections.DeviceCards
import com.hydra.android.feature.dashboard.sections.GpuSection
import com.hydra.android.feature.dashboard.sections.OfflineAlert
import com.hydra.android.feature.dashboard.sections.RecentTasksSection
import com.hydra.android.feature.dashboard.sections.RunningOrchsSection
import com.hydra.android.feature.dashboard.sections.ServerStatusBanner
import com.hydra.android.feature.dashboard.sections.SummaryGrid

/**
 * Section order follows HydraiOS/Screens/DashboardScreen.swift:9-115 exactly,
 * minus the Quick Command block — v1 routes command execution through Chat.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(viewModel: DashboardViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snapshot = state.snapshot

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("대시보드") },
                actions = {
                    // Mirrors the iOS toolbar: a spinner while a load is in
                    // flight, otherwise a manual refresh. Pull-to-refresh is
                    // still there; this is the affordance you can reach without
                    // scrolling a long dashboard back to the top.
                    if (state.isLoading) {
                        CircularProgressIndicator(
                            Modifier
                                .padding(end = 16.dp)
                                .size(20.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        IconButton(onClick = viewModel::refresh) {
                            Icon(Icons.Filled.Refresh, contentDescription = "새로고침")
                        }
                    }
                },
            )
        }
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isLoading && !state.showBlockingLoader,
            onRefresh = viewModel::refresh,
            modifier = Modifier.padding(padding),
        ) {
            LazyColumn(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { ServerStatusBanner(snapshot.serverStatus, snapshot.serverVersion) }

                if (snapshot.offlineDevices.isNotEmpty()) {
                    item { OfflineAlert(snapshot.offlineDevices) }
                }

                item { SummaryGrid(snapshot) }
                item { DeviceCards(snapshot.devices, snapshot.metricsByDevice) }

                if (snapshot.gpuNodes.isNotEmpty()) {
                    item {
                        GpuSection(
                            nodes = snapshot.gpuNodes,
                            avgUtilization = snapshot.avgGpuUtilization,
                            vramUsedGb = snapshot.totalVramUsedGb,
                            vramTotalGb = snapshot.totalVramTotalGb,
                        )
                    }
                }

                if (snapshot.runningOrchs.isNotEmpty()) {
                    item { RunningOrchsSection(snapshot.runningOrchs, snapshot.devices) }
                }

                item { RecentTasksSection(snapshot.recentTasks, snapshot.devices) }

                snapshot.error?.let { error ->
                    item {
                        Text(
                            error,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }

                state.lastRefresh?.let { at ->
                    item {
                        Text(
                            "Last updated: $at",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            if (state.showBlockingLoader) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
        }
    }
}
