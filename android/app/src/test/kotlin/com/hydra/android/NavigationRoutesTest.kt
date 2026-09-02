package com.hydra.android

import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import org.junit.Assert.assertEquals
import org.junit.Test

class NavigationRoutesTest {

    @Test
    fun `bottom tabs are ordered dashboard, chat, settings`() {
        assertEquals(
            listOf(DASHBOARD_ROUTE, CHAT_ROUTE, SETTINGS_ROUTE),
            HydraDestination.entries.map { it.route },
        )
    }

    @Test
    fun `tab labels match the iOS wording`() {
        assertEquals(
            listOf("대시보드", "Chat", "설정"),
            HydraDestination.entries.map { it.label },
        )
    }

    @Test
    fun `the start destination is the dashboard`() {
        assertEquals(DASHBOARD_ROUTE, HydraDestination.START_ROUTE)
    }

    @Test
    fun `routes are unique`() {
        val routes = HydraDestination.entries.map { it.route }
        assertEquals(routes.size, routes.toSet().size)
    }
}
