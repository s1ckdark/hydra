package com.hydra.android.core.ssh

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class HostKeyGateTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun store(vararg lines: String) =
        KnownHostsStore(File(temp.root, "kh").apply { writeText(lines.joinToString("\n")) })

    private val fp = HostKeyFingerprint("ssh-ed25519", "AAAAKEY", "SHA256:abc")

    @Test
    fun `a known matching key proceeds`() {
        val d = HostKeyGate.evaluate("10.0.0.1", fp, store("10.0.0.1 ssh-ed25519 AAAAKEY"))
        assertEquals(HostKeyDecision.Proceed, d)
    }

    @Test
    fun `an unknown host needs trust and carries the fingerprint`() {
        val d = HostKeyGate.evaluate("10.0.0.1", fp, store())
        assertEquals(HostKeyDecision.NeedsTrust("SHA256:abc"), d)
    }

    @Test
    fun `a changed key is blocked without prompting`() {
        val d = HostKeyGate.evaluate("10.0.0.1", fp, store("10.0.0.1 ssh-ed25519 DIFFERENT"))
        assertEquals(HostKeyDecision.Blocked, d)
    }

    @Test
    fun `a missing fingerprint is blocked`() {
        val d = HostKeyGate.evaluate("10.0.0.1", null, store())
        assertEquals(HostKeyDecision.Blocked, d)
    }
}
