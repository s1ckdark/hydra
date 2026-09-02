package com.hydra.android.feature.dashboard.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.HydraPurple
import com.hydra.android.core.model.GpuNodeStatus

@Composable
fun GpuSection(
    nodes: List<GpuNodeStatus>,
    avgUtilization: Double,
    vramUsedGb: Double,
    vramTotalGb: Double,
) {
    if (nodes.isEmpty()) return
    HydraCard {
        Text("GPU", style = MaterialTheme.typography.titleSmall)
        Row(
            Modifier
                .fillMaxWidth()
                .padding(vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("평균 사용률 %.0f%%".format(avgUtilization),
                style = MaterialTheme.typography.bodySmall, color = HydraPurple)
            Text("VRAM %.1f / %.1f GB".format(vramUsedGb, vramTotalGb),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        nodes.forEach { node -> GpuNodeRow(node) }
    }
}

@Composable
private fun GpuNodeRow(node: GpuNodeStatus) {
    Column(Modifier.padding(top = 8.dp)) {
        Text(
            node.deviceName.ifEmpty { node.deviceId },
            style = MaterialTheme.typography.labelMedium,
        )
        // A node that failed to report shows why instead of empty gauges.
        if (node.hasError) {
            Text(
                node.error.orEmpty(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.error,
            )
            return@Column
        }
        node.gpus.orEmpty().forEach { gpu ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    "#${gpu.index}",
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.weight(0.12f),
                )
                LinearProgressIndicator(
                    progress = { (gpu.utilizationPercent / 100).toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.weight(0.5f),
                )
                Text(
                    "%.0f%% · %.0f°C".format(gpu.utilizationPercent, gpu.temperatureC.toDouble()),
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.weight(0.38f),
                )
            }
        }
    }
}
