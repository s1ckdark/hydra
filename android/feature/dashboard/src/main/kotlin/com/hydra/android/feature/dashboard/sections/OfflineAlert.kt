package com.hydra.android.feature.dashboard.sections

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.model.Device

/** Rendered only when the list is non-empty — the caller makes that decision. */
@Composable
fun OfflineAlert(devices: List<Device>) {
    HydraCard {
        Text(
            "오프라인 ${devices.size}대",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.error,
        )
        Text(
            devices.joinToString(", ") { it.shortName },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
