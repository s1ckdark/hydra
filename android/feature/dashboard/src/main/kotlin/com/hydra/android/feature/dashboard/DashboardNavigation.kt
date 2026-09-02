package com.hydra.android.feature.dashboard

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val DASHBOARD_ROUTE = "dashboard"

fun NavGraphBuilder.dashboardScreen() {
    composable(DASHBOARD_ROUTE) { DashboardScreen() }
}
