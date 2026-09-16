package com.hydra.android.feature.orchs

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument

const val ORCHS_ROUTE = "orchs"
const val CREATE_ORCH_ROUTE = "orchs/create"
const val ORCH_DETAIL_ROUTE = "orchs/{orchId}"

fun orchDetailRoute(orchId: String) = "orchs/$orchId"

fun NavGraphBuilder.orchsScreens(
    onOpenDetail: (String) -> Unit,
    onOpenCreate: () -> Unit,
    onBack: () -> Unit,
) {
    composable(ORCHS_ROUTE) {
        OrchsScreen(onOpenDetail = onOpenDetail, onOpenCreate = onOpenCreate)
    }
    composable(CREATE_ORCH_ROUTE) {
        CreateOrchScreen(onDone = onBack, onBack = onBack)
    }
    composable(
        ORCH_DETAIL_ROUTE,
        arguments = listOf(navArgument("orchId") { type = NavType.StringType }),
    ) { entry ->
        OrchDetailScreen(
            orchId = entry.arguments?.getString("orchId").orEmpty(),
            onBack = onBack,
        )
    }
}
