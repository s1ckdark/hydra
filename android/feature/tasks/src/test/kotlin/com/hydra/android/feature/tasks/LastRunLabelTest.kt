package com.hydra.android.feature.tasks

import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test

class LastRunLabelTest {

    private val seoul = TimeZone.of("Asia/Seoul")

    // Found on device: the row read "success · 2026-09-04T05:44:10.454778Z".
    @Test
    fun `a run is labelled with its local date and time`() {
        val at = Instant.parse("2026-09-04T05:44:10.454778Z")
        assertEquals("success · 09-04 14:44", lastRunLabel("success", at, seoul))
    }

    @Test
    fun `the status alone is used when there is no timestamp`() {
        assertEquals("failed", lastRunLabel("failed", null, seoul))
    }

    @Test
    fun `single-digit fields are padded`() {
        val at = Instant.parse("2026-01-02T00:05:00Z")
        assertEquals("success · 01-02 09:05", lastRunLabel("success", at, seoul))
    }
}
