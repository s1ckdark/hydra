package com.hydra.android.feature.devices

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val DEVICES_ROUTE = "devices"

fun NavGraphBuilder.devicesScreen(onSelectDevice: (String) -> Unit) {
    composable(DEVICES_ROUTE) { DevicesScreen(onSelectDevice = onSelectDevice) }
}
