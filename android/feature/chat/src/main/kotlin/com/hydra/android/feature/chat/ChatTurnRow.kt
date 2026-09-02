package com.hydra.android.feature.chat

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.hydra.android.core.model.ChatTurn

/** One row in the chat history, adapted from iOS ChatTurnRow. */
@Composable
fun ChatTurnRow(turn: ChatTurn) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            turn.roleLabel(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(turn.content, style = MaterialTheme.typography.bodyMedium)
    }
}

private fun ChatTurn.roleLabel(): String = when (role) {
    "user" -> "YOU"
    "assistant_ask" -> "ASK"
    "assistant_plan" -> "PLAN"
    "system_result" -> "RESULT"
    else -> role.uppercase()
}
