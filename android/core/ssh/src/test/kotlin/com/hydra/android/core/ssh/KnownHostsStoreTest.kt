package com.hydra.android.core.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class KnownHostsStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun store(vararg lines: String): KnownHostsStore {
        val f = File(temp.root, "known_hosts")
        f.writeText(lines.joinToString("\n"))
        return KnownHostsStore(f)
    }

    private fun entry(host: String, type: String = "ssh-ed25519", key: String = "AAAAKEY") =
        KnownHostsEntry(host, type, key)

    @Test
    fun `an unseen host reads as unknown`() {
        assertEquals(KnownHostsCheck.UNKNOWN, store().check(entry("10.0.0.1")))
    }

    @Test
    fun `a stored host with the same key reads as match`() {
        val s = store("10.0.0.1 ssh-ed25519 AAAAKEY")
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `a stored host with a different key of the same type reads as mismatch`() {
        val s = store("10.0.0.1 ssh-ed25519 OTHERKEY")
        assertEquals(KnownHostsCheck.MISMATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `a different key type for a known host reads as unknown, never mismatch`() {
        // A host legitimately serves several key types. Matching on host alone
        // would report a mismatch for a host merely offering a different type,
        // which is a false machine-in-the-middle alarm. (iOS patch I3.)
        val s = store("10.0.0.1 ssh-rsa RSAKEY")
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(entry("10.0.0.1", "ssh-ed25519", "EDKEY")))
    }

    @Test
    fun `another host's entry does not satisfy this host`() {
        val s = store("10.0.0.2 ssh-ed25519 AAAAKEY")
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `blank lines and comments are ignored`() {
        val s = store("", "# a comment", "10.0.0.1 ssh-ed25519 AAAAKEY", "")
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `malformed lines are skipped rather than throwing`() {
        val s = store("garbage", "10.0.0.1 ssh-ed25519 AAAAKEY")
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `a missing file reads as unknown rather than throwing`() {
        val s = KnownHostsStore(File(temp.root, "does-not-exist"))
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `add persists an entry that then matches`() {
        val f = File(temp.root, "known_hosts")
        val s = KnownHostsStore(f)
        s.add(entry("10.0.0.1"))
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
        assertTrue(f.readText().contains("10.0.0.1 ssh-ed25519 AAAAKEY"))
    }

    @Test
    fun `add keeps existing entries`() {
        val f = File(temp.root, "known_hosts")
        f.writeText("10.0.0.2 ssh-rsa RSAKEY\n")
        val s = KnownHostsStore(f)
        s.add(entry("10.0.0.1"))
        assertEquals(2, s.readAll().size)
    }
}
