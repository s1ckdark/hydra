package com.hydra.android.feature.devices

import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.StatusDot
import com.hydra.android.core.model.Device

/**
 * Feature-for-feature with HydraiOS/Screens/DeviceListScreen.swift: name,
 * Tailscale IP, an online dot, and a terminal affordance only where SSH is
 * available. Rows without SSH are inert, as iOS's `.disabled(!sshEnabled)`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(
    onSelectDevice: (String) -> Unit,
    viewModel: DevicesViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    Scaffold(topBar = { TopAppBar(title = { Text("디바이스") }) }) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isLoading && state.devices.isNotEmpty(),
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
                items(state.devices, key = { it.id }) { device ->
                    DeviceRow(device, onSelectDevice)
                }
            }

            if (state.isLoading && state.devices.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
        }
    }
}

@Composable
private fun DeviceRow(device: Device, onSelect: (String) -> Unit) {
    HydraCard(
        Modifier.clickable(enabled = device.sshEnabled) { onSelect(device.id) }
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                // A row you cannot open should look like one.
                .alpha(if (device.sshEnabled) 1f else 0.4f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(device.isOnline)
                Column(Modifier.padding(start = 8.dp)) {
                    Text(device.displayName, style = MaterialTheme.typography.titleSmall)
                    Text(
                        device.tailscaleIp.ifEmpty { device.hostname },
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (device.sshEnabled) {
                Icon(
                    Icons.Filled.Terminal,
                    contentDescription = "터미널 열기",
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}
