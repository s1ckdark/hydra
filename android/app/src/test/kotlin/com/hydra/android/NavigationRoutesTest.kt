package com.hydra.android

import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.devices.DEVICES_ROUTE
import com.hydra.android.feature.terminal.terminalRoute
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationRoutesTest {

    @Test
    fun `bottom tabs are ordered dashboard, devices, chat, settings`() {
        assertEquals(
            listOf(DASHBOARD_ROUTE, DEVICES_ROUTE, CHAT_ROUTE, SETTINGS_ROUTE),
            HydraDestination.entries.map { it.route },
        )
    }

    @Test
    fun `tab labels match the iOS wording`() {
        assertEquals(
            listOf("대시보드", "디바이스", "Chat", "설정"),
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
    fun `terminalRoute substitutes the device id`() {
        assertEquals("terminal/d1", terminalRoute("d1"))
    }

    @Test
    fun `routes are unique`() {
        val routes = HydraDestination.entries.map { it.route }
        assertEquals(routes.size, routes.toSet().size)
    }
}
