package com.hydra.android.feature.dashboard.sections

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.hydra.android.core.data.ServerStatus
import com.hydra.android.core.designsystem.HydraGreen

@Composable
fun ServerStatusBanner(status: ServerStatus, version: String) {
    val (label, tint) = when (status) {
        ServerStatus.CONNECTED ->
            (if (version.isEmpty()) "연결됨" else "연결됨 · v$version") to HydraGreen
        ServerStatus.DISCONNECTED ->
            "서버에 연결할 수 없습니다" to MaterialTheme.colorScheme.error
        ServerStatus.UNKNOWN ->
            "확인 중…" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(
        Modifier
            .fillMaxWidth()
            .background(tint.copy(alpha = 0.15f), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = tint.solid())
    }
}

/** Keeps the label readable when the tint is used at low alpha for the fill. */
private fun Color.solid(): Color = copy(alpha = 1f)
