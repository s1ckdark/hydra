package com.hydra.android.feature.dashboard.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.HydraBlue
import com.hydra.android.core.designsystem.HydraGreen
import com.hydra.android.core.designsystem.HydraOrange
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.NagaTask

@Composable
fun RecentTasksSection(tasks: List<NagaTask>, devices: List<Device>) {
    HydraCard {
        Text("최근 Tasks", style = MaterialTheme.typography.titleSmall)
        if (tasks.isEmpty()) {
            Text(
                "표시할 작업이 없습니다",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp),
            )
            return@HydraCard
        }
        tasks.forEach { task ->
            val deviceName = devices.firstOrNull { it.id == task.assignedDeviceId }?.shortName
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val (icon, tint) = task.statusIcon()
                Icon(icon, contentDescription = task.status, tint = tint,
                    modifier = Modifier.size(16.dp))
                Text(task.type, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(1f))
                Text(
                    deviceName ?: "-",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** Status glyphs mirror ServerTask.swift's statusIcon mapping. */
@Composable
private fun NagaTask.statusIcon(): Pair<ImageVector, Color> = when (status) {
    "running" -> Icons.Filled.PlayCircle to HydraBlue
    "completed" -> Icons.Filled.CheckCircle to HydraGreen
    "failed" -> Icons.Filled.Cancel to MaterialTheme.colorScheme.error
    "queued", "assigned", "pending" -> Icons.Filled.Schedule to HydraOrange
    "cancelled" -> Icons.Filled.RemoveCircle to MaterialTheme.colorScheme.onSurfaceVariant
    else -> Icons.Filled.HelpOutline to MaterialTheme.colorScheme.onSurfaceVariant
}
