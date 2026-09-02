package com.hydra.android.feature.dashboard.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.Orch

@Composable
fun RunningOrchsSection(orchs: List<Orch>, devices: List<Device>) {
    if (orchs.isEmpty()) return
    HydraCard {
        Text("실행 중 Orchs", style = MaterialTheme.typography.titleSmall)
        orchs.forEach { orch ->
            val coordinator = devices.firstOrNull { it.id == orch.coordinatorId }?.shortName
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text(orch.name, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        listOfNotNull(orch.mode.ifEmpty { null }, coordinator)
                            .joinToString(" · "),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    "${orch.workerCount} workers",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
