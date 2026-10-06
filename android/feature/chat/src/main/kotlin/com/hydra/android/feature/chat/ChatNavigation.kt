package com.hydra.android.feature.chat

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val CHAT_ROUTE = "chat"

fun NavGraphBuilder.chatScreen(viewModel: ChatViewModel? = null) {
    composable(CHAT_ROUTE) {
        if (viewModel == null) ChatScreen() else ChatScreen(viewModel)
    }
}
