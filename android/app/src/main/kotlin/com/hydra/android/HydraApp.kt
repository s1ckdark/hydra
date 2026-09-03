package com.hydra.android

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.chat.chatScreen
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.dashboard.dashboardScreen
import com.hydra.android.feature.devices.DEVICES_ROUTE
import com.hydra.android.feature.devices.devicesScreen
import com.hydra.android.feature.terminal.terminalRoute
import com.hydra.android.feature.terminal.terminalScreen
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import com.hydra.android.feature.settings.SSH_KEY_ROUTE
import com.hydra.android.feature.settings.settingsScreen

/**
 * The four shipped tabs. The iOS app has six; Orchs and Tasks are still
 * absent rather than stubbed. The terminal is not a tab — it is a full-screen
 * route, matching iOS's fullScreenCover.
 */
enum class HydraDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
) {
    DASHBOARD(DASHBOARD_ROUTE, "대시보드", Icons.Filled.Speed),
    DEVICES(DEVICES_ROUTE, "디바이스", Icons.Filled.Dns),
    CHAT(CHAT_ROUTE, "Chat", Icons.AutoMirrored.Filled.Chat),
    SETTINGS(SETTINGS_ROUTE, "설정", Icons.Filled.Settings),
    ;

    companion object {
        const val START_ROUTE = DASHBOARD_ROUTE
    }
}

@Composable
fun HydraApp() {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route

    // Full-screen destinations own the whole window.
    val hideBottomBar = currentRoute?.startsWith("terminal/") == true ||
        currentRoute == SSH_KEY_ROUTE

    Scaffold(
        bottomBar = {
            if (hideBottomBar) return@Scaffold
            NavigationBar {
                HydraDestination.entries.forEach { destination ->
                    NavigationBarItem(
                        selected = currentRoute == destination.route,
                        onClick = {
                            navController.navigate(destination.route) {
                                // Single-top tab switching: don't stack copies
                                // of a tab, and keep each tab's own state
                                // across switches.
                                popUpTo(navController.graph.findStartDestination().id) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = {
                            Icon(destination.icon, contentDescription = destination.label)
                        },
                        label = { Text(destination.label) },
                    )
                }
            }
        }
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = HydraDestination.START_ROUTE,
            modifier = Modifier.padding(padding),
        ) {
            dashboardScreen()
            devicesScreen(onSelectDevice = { id -> navController.navigate(terminalRoute(id)) })
            chatScreen()
            settingsScreen(
                onOpenSshKey = { navController.navigate(SSH_KEY_ROUTE) },
                onBack = { navController.popBackStack() },
            )
            terminalScreen(onClose = { navController.popBackStack() })
        }
    }
}
