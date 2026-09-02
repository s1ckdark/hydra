package com.hydra.android

import org.junit.Assert.assertEquals
import org.junit.Test

class BuildSmokeTest {
    @Test
    fun `module builds and runs unit tests`() {
        assertEquals(
            "com.hydra.android.HydraApplication",
            HydraApplication::class.java.name,
        )
    }
}
