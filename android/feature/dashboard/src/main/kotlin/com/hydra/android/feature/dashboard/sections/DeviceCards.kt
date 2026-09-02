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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.StatusDot
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.DeviceMetrics

@Composable
fun DeviceCards(devices: List<Device>, metrics: Map<String, DeviceMetrics>) {
    if (devices.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("디바이스", style = MaterialTheme.typography.titleSmall)
        devices.forEach { device ->
            DeviceCard(device, metrics[device.id])
        }
    }
}

@Composable
private fun DeviceCard(device: Device, metrics: DeviceMetrics?) {
    HydraCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(device.isOnline)
            Text(
                device.shortName,
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(start = 8.dp),
            )
            Text(
                device.os,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        // A device with no metrics sample shows an em dash, not 0% — a missing
        // sample is not a zero sample, and the two must not look alike.
        UsageRow("CPU", metrics?.cpu?.usagePercent)
        UsageRow("RAM", metrics?.memory?.usagePercent)
        if (device.hasGpu) {
            Text(
                "GPU: ${device.gpuModel ?: "-"} ×${device.gpuCount}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        metrics?.error?.takeIf { it.isNotEmpty() }?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun UsageRow(label: String, percent: Double?) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(0.15f))
        if (percent == null) {
            Text(
                "—",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(0.85f),
            )
        } else {
            LinearProgressIndicator(
                progress = { (percent / 100).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.weight(0.6f),
            )
            Text(
                "%.0f%%".format(percent),
                style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.weight(0.25f),
            )
        }
    }
}
