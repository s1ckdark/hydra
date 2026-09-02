package com.hydra.android.feature.chat

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val CHAT_ROUTE = "chat"

fun NavGraphBuilder.chatScreen() {
    composable(CHAT_ROUTE) { ChatScreen() }
}
