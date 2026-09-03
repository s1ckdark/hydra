package com.hydra.android.feature.terminal

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument

const val TERMINAL_ROUTE = "terminal/{deviceId}"

fun terminalRoute(deviceId: String) = "terminal/$deviceId"

fun NavGraphBuilder.terminalScreen(onClose: () -> Unit) {
    composable(
        TERMINAL_ROUTE,
        arguments = listOf(navArgument("deviceId") { type = NavType.StringType }),
    ) { entry ->
        TerminalScreen(
            deviceId = entry.arguments?.getString("deviceId").orEmpty(),
            onClose = onClose,
        )
    }
}
