package com.hydra.android

import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.devices.DEVICES_ROUTE
import com.hydra.android.feature.orchs.CREATE_ORCH_ROUTE
import com.hydra.android.feature.orchs.ORCHS_ROUTE
import com.hydra.android.feature.orchs.orchDetailRoute
import com.hydra.android.feature.tasks.TASKS_ROUTE
import com.hydra.android.feature.tasks.taskEditorRoute
import com.hydra.android.feature.terminal.terminalRoute
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationRoutesTest {

    @Test
    fun `bottom tabs are ordered dashboard, devices, orchs, tasks, chat, settings`() {
        assertEquals(
            listOf(
                DASHBOARD_ROUTE,
                DEVICES_ROUTE,
                ORCHS_ROUTE,
                TASKS_ROUTE,
                CHAT_ROUTE,
                SETTINGS_ROUTE,
            ),
            HydraDestination.entries.map { it.route },
        )
    }

    @Test
    fun `tab labels match the iOS wording`() {
        assertEquals(
            listOf("대시보드", "디바이스", "Orchs", "Tasks", "Chat", "설정"),
            HydraDestination.entries.map { it.label },
        )
    }

    @Test
    fun `the start destination is the dashboard`() {
        assertEquals(DASHBOARD_ROUTE, HydraDestination.START_ROUTE)
    }

    @Test
    fun `the terminal is not a tab`() {
        // It is a full-screen route, matching iOS's fullScreenCover.
        assertTrue(HydraDestination.entries.none { it.route.startsWith("terminal") })
    }

    @Test
    fun `full-screen routes are not tabs`() {
        // Orch create/detail and the task editor are full-screen, like the terminal.
        val tabRoutes = HydraDestination.entries.map { it.route }
        assertTrue(CREATE_ORCH_ROUTE !in tabRoutes)
        assertTrue(orchDetailRoute("o1") !in tabRoutes)
        assertTrue(taskEditorRoute("t1") !in tabRoutes)
    }

    @Test
    fun `route builders substitute their ids`() {
        assertEquals("terminal/d1", terminalRoute("d1"))
        assertEquals("orchs/o1", orchDetailRoute("o1"))
        assertEquals("tasks/edit?taskId=t1", taskEditorRoute("t1"))
        assertEquals("tasks/edit?taskId=", taskEditorRoute(null))
    }

    @Test
    fun `routes are unique`() {
        val routes = HydraDestination.entries.map { it.route }
        assertEquals(routes.size, routes.toSet().size)
    }
}
