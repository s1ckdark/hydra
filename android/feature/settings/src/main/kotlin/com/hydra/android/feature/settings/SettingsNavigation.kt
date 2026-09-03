package com.hydra.android.feature.settings

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val SETTINGS_ROUTE = "settings"
const val SSH_KEY_ROUTE = "settings/ssh-key"

fun NavGraphBuilder.settingsScreen(
    onOpenSshKey: () -> Unit,
    onBack: () -> Unit,
) {
    composable(SETTINGS_ROUTE) { SettingsScreen(onOpenSshKey = onOpenSshKey) }
    composable(SSH_KEY_ROUTE) { SshKeyScreen(onBack = onBack) }
}
