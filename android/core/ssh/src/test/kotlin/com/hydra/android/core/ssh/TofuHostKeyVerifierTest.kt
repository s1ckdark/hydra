package com.hydra.android.core.ssh

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TofuHostKeyVerifierTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun store(vararg lines: String) =
        KnownHostsStore(File(temp.root, "kh").apply { writeText(lines.joinToString("\n")) })

    private val fp = HostKeyFingerprint("ssh-ed25519", "AAAAKEY", "SHA256:abc")

    @Test
    fun `a known key verifies without prompting`() = runBlocking {
        var prompted = false
        val v = TofuHostKeyVerifier(store("h1 ssh-ed25519 AAAAKEY")) { prompted = true; true }
        assertTrue(v.decide("h1", fp))
        assertFalse(prompted)
    }

    @Test
    fun `an unknown key prompts and stores on acceptance`() = runBlocking {
        val s = store()
        val v = TofuHostKeyVerifier(s) { true }
        assertTrue(v.decide("h1", fp))
        assertEquals(
            KnownHostsCheck.MATCH,
            s.check(KnownHostsEntry("h1", "ssh-ed25519", "AAAAKEY")),
        )
    }

    @Test
    fun `an unknown key rejected by the user does not verify and is not stored`() = runBlocking {
        val s = store()
        val v = TofuHostKeyVerifier(s) { false }
        assertFalse(v.decide("h1", fp))
        assertEquals(
            KnownHostsCheck.UNKNOWN,
            s.check(KnownHostsEntry("h1", "ssh-ed25519", "AAAAKEY")),
        )
    }

    @Test
    fun `a mismatched key is rejected without prompting`() = runBlocking {
        var prompted = false
        val v = TofuHostKeyVerifier(store("h1 ssh-ed25519 OTHER")) { prompted = true; true }
        assertFalse(v.decide("h1", fp))
        assertFalse(prompted)
    }

    @Test
    fun `the last decision is recorded so the transport can explain a rejection`() = runBlocking {
        val v = TofuHostKeyVerifier(store("h1 ssh-ed25519 OTHER")) { true }
        v.decide("h1", fp)
        assertEquals(HostKeyDecision.Blocked, v.lastDecision)
    }
}
