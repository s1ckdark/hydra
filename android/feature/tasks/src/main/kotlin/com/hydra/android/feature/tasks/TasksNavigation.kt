package com.hydra.android.feature.tasks

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument

const val TASKS_ROUTE = "tasks"
const val TASK_EDITOR_ROUTE = "tasks/edit?taskId={taskId}"

fun taskEditorRoute(taskId: String?) =
    if (taskId == null) "tasks/edit?taskId=" else "tasks/edit?taskId=$taskId"

fun NavGraphBuilder.tasksScreens(
    onOpenEditor: (String?) -> Unit,
    onBack: () -> Unit,
) {
    composable(TASKS_ROUTE) { TasksScreen(onOpenEditor = onOpenEditor) }
    composable(
        TASK_EDITOR_ROUTE,
        arguments = listOf(
            navArgument("taskId") { type = NavType.StringType; defaultValue = "" },
        ),
    ) { entry ->
        TaskEditorScreen(
            taskId = entry.arguments?.getString("taskId")?.ifEmpty { null },
            onDone = onBack,
            onBack = onBack,
        )
    }
}
