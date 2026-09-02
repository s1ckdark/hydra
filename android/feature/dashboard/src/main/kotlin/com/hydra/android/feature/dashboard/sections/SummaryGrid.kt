package com.hydra.android.feature.dashboard.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.hydra.android.core.data.DashboardSnapshot
import com.hydra.android.core.designsystem.HydraBlue
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.HydraGreen
import com.hydra.android.core.designsystem.HydraOrange
import com.hydra.android.core.designsystem.HydraPurple

/**
 * Four cards in a 2x2 grid, in the order and accents of
 * DashboardScreen.swift:19-47. Laid out as two Rows rather than a
 * LazyVerticalGrid: this sits inside a LazyColumn, and nesting a lazy
 * vertical scroller inside another one is not allowed.
 */
@Composable
fun SummaryGrid(snapshot: DashboardSnapshot) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SummaryCard(
                Modifier.weight(1f), "Devices",
                "${snapshot.onlineDevices.size}/${snapshot.devices.size}",
                "online", Icons.Filled.Computer, HydraBlue,
            )
            SummaryCard(
                Modifier.weight(1f), "GPU Nodes",
                "${snapshot.gpuDevices.size}",
                "${snapshot.totalGpus} GPUs total", Icons.Filled.Memory, HydraPurple,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SummaryCard(
                Modifier.weight(1f), "Orchs",
                "${snapshot.orchs.size}",
                "${snapshot.runningOrchs.size} running", Icons.Filled.Dns, HydraGreen,
            )
            SummaryCard(
                Modifier.weight(1f), "Tasks",
                "${snapshot.runningTasks.size}",
                "${snapshot.tasks.size} total", Icons.AutoMirrored.Filled.List, HydraOrange,
            )
        }
    }
}

@Composable
private fun SummaryCard(
    modifier: Modifier,
    title: String,
    value: String,
    subtitle: String,
    icon: ImageVector,
    accent: Color,
) {
    HydraCard(modifier) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = MaterialTheme.typography.labelMedium)
            Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(18.dp))
        }
        Text(value, style = MaterialTheme.typography.headlineSmall, color = accent)
        Text(
            subtitle,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
