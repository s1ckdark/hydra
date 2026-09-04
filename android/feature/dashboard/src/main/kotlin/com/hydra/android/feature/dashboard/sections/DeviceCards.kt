package com.hydra.android.feature.dashboard.sections

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.designsystem.HydraOrange
import com.hydra.android.core.designsystem.StatusDot
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.DeviceMetrics

/** What the body of a device card should show. */
enum class DeviceCardBody { Usage, Gpu, Address }

/** Why a device's metrics are missing, when they are. */
enum class DeviceHealthBadge { COOLING_DOWN, UNREACHABLE }

/**
 * Mirrors iOS `DashboardDeviceCard`: usage bars only when the sample is
 * healthy, otherwise a GPU line or the address.
 *
 * Rendering 0% bars beside a collection failure would read as "idle" rather
 * than "unknown", which is the worse of the two mistakes.
 */
fun deviceCardBody(device: Device, metrics: DeviceMetrics?): DeviceCardBody = when {
    metrics == null || !metrics.hasError -> DeviceCardBody.Usage
    device.hasGpu -> DeviceCardBody.Gpu
    else -> DeviceCardBody.Address
}

/**
 * The circuit breaker declining to dial is an operational state, not a fault,
 * so it gets its own label rather than the error treatment — as on iOS, where
 * it draws a "zzz" icon instead of a warning triangle.
 *
 * The raw error text is deliberately not surfaced here: it is a multi-line SSH
 * diagnostic that belongs on a device detail screen, not pinned inside a list
 * card where it never goes away.
 */
fun deviceHealthBadge(metrics: DeviceMetrics?): DeviceHealthBadge? = when {
    metrics == null || !metrics.hasError -> null
    metrics.isSuppressed -> DeviceHealthBadge.COOLING_DOWN
    else -> DeviceHealthBadge.UNREACHABLE
}

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
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
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
            deviceHealthBadge(metrics)?.let { badge ->
                HealthBadge(badge, Modifier.padding(start = 8.dp))
            }
        }

        when (deviceCardBody(device, metrics)) {
            DeviceCardBody.Usage -> {
                // A device with no sample shows an em dash, not 0% — a missing
                // sample is not a zero sample.
                UsageRow("CPU", metrics?.cpu?.usagePercent)
                UsageRow("RAM", metrics?.memory?.usagePercent)
            }

            DeviceCardBody.Gpu -> Text(
                "GPU: ${device.gpuModel ?: "-"} ×${device.gpuCount}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp),
            )

            DeviceCardBody.Address -> Text(
                device.tailscaleIp.ifEmpty { device.os },
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp),
            )
        }

        if (device.hasGpu && deviceCardBody(device, metrics) == DeviceCardBody.Usage) {
            Text(
                "GPU: ${device.gpuModel ?: "-"} ×${device.gpuCount}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun HealthBadge(badge: DeviceHealthBadge, modifier: Modifier = Modifier) {
    val (label, tint) = when (badge) {
        DeviceHealthBadge.COOLING_DOWN -> "대기 중" to HydraOrange
        DeviceHealthBadge.UNREACHABLE -> "연결 실패" to MaterialTheme.colorScheme.error
    }
    Text(
        label,
        style = MaterialTheme.typography.labelSmall,
        color = tint,
        modifier = modifier
            .background(tint.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 1.dp),
    )
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
