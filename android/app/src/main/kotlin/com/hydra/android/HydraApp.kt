package com.hydra.android

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Hub
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
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.chat.ChatViewModel
import com.hydra.android.feature.chat.chatScreen
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.dashboard.dashboardScreen
import com.hydra.android.feature.devices.DEVICES_ROUTE
import com.hydra.android.feature.devices.devicesScreen
import com.hydra.android.feature.orchs.CREATE_ORCH_ROUTE
import com.hydra.android.feature.orchs.ORCHS_ROUTE
import com.hydra.android.feature.orchs.orchDetailRoute
import com.hydra.android.feature.orchs.orchsScreens
import com.hydra.android.feature.tasks.TASKS_ROUTE
import com.hydra.android.feature.tasks.taskEditorRoute
import com.hydra.android.feature.tasks.tasksScreens
import com.hydra.android.feature.terminal.terminalRoute
import com.hydra.android.feature.terminal.terminalScreen
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import com.hydra.android.feature.settings.SSH_KEY_ROUTE
import com.hydra.android.feature.settings.settingsScreen

/**
 * The six tabs, in the iOS order. The terminal, the orch create/detail
 * screens and the task editor are not tabs — they are full-screen routes,
 * matching iOS's fullScreenCover and navigation pushes.
 */
enum class HydraDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
) {
    DASHBOARD(DASHBOARD_ROUTE, "대시보드", Icons.Filled.Speed),
    DEVICES(DEVICES_ROUTE, "디바이스", Icons.Filled.Dns),
    ORCHS(ORCHS_ROUTE, "Orchs", Icons.Filled.Hub),
    TASKS(TASKS_ROUTE, "Tasks", Icons.AutoMirrored.Filled.ListAlt),
    CHAT(CHAT_ROUTE, "Chat", Icons.AutoMirrored.Filled.Chat),
    SETTINGS(SETTINGS_ROUTE, "설정", Icons.Filled.Settings),
    ;

    companion object {
        const val START_ROUTE = DASHBOARD_ROUTE
    }
}

@Composable
fun HydraApp(chatViewModel: ChatViewModel = hiltViewModel()) {
    val navController = rememberNavController()
    // Keep the chat session at the activity level so switching to Orchs does
    // not discard its running stream, captured model selection, or approval.
    val chatState by chatViewModel.state.collectAsStateWithLifecycle()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route

    // Full-screen destinations own the whole window.
    val hideBottomBar = currentRoute?.startsWith("terminal/") == true ||
        currentRoute == SSH_KEY_ROUTE ||
        currentRoute == CREATE_ORCH_ROUTE ||
        currentRoute?.startsWith("orchs/") == true ||
        currentRoute?.startsWith("tasks/edit") == true

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
            orchsScreens(
                onOpenDetail = { id -> navController.navigate(orchDetailRoute(id)) },
                onOpenCreate = { navController.navigate(CREATE_ORCH_ROUTE) },
                onBack = { navController.popBackStack() },
                onOpenAgentChat = { target ->
                    if (chatViewModel.selectAgent(target)) {
                        navController.navigate(CHAT_ROUTE) {
                            popUpTo(navController.graph.findStartDestination().id) {
                                saveState = true
                            }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                },
                canSwitchAgent = chatState.canSwitchAgent,
                agentRun = chatState.agentRun,
                runOrchestrationId = chatState.runOrchestrationId,
                progressDisconnected = chatState.progressDisconnected,
                progressUnavailable = chatState.progressUnavailable,
            )
            tasksScreens(
                onOpenEditor = { id -> navController.navigate(taskEditorRoute(id)) },
                onBack = { navController.popBackStack() },
            )
            chatScreen(viewModel = chatViewModel)
            settingsScreen(
                onOpenSshKey = { navController.navigate(SSH_KEY_ROUTE) },
                onBack = { navController.popBackStack() },
            )
            terminalScreen(onClose = { navController.popBackStack() })
        }
    }
}
