package com.hydra.android.core.ssh

import android.util.Base64
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import java.security.MessageDigest
import java.security.PublicKey

/** OpenSSH-style identity of a presented host key. */
fun fingerprintOf(key: PublicKey): HostKeyFingerprint {
    val wire = Buffer.PlainBuffer().putPublicKey(key).compactData
    val sha = MessageDigest.getInstance("SHA-256").digest(wire)
    return HostKeyFingerprint(
        keyType = KeyType.fromKey(key).toString(),
        publicKeyBase64 = Base64.encodeToString(wire, Base64.NO_WRAP),
        sha256 = "SHA256:" + Base64.encodeToString(sha, Base64.NO_WRAP or Base64.NO_PADDING),
    )
}

/**
 * TOFU inside the handshake. sshj calls [verify] synchronously on the
 * transport's own IO thread, so blocking it on the user's answer is safe — it
 * is never the main thread.
 *
 * This sits earlier than iOS's equivalent: iOS checks trust between connect()
 * and openShell() because libssh2 does not enforce host keys itself. Here an
 * untrusted key never reaches an authenticated session at all.
 */
class TofuHostKeyVerifier(
    private val store: KnownHostsStore,
    private val onNeedsTrust: suspend (HostKeyFingerprint) -> Boolean,
) : HostKeyVerifier {

    /** Set on every decision so the transport can explain a rejection. */
    @Volatile
    var lastDecision: HostKeyDecision = HostKeyDecision.Blocked
        private set

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean =
        runBlocking { decide(hostname, fingerprintOf(key)) }

    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> =
        store.readAll().filter { it.host == hostname }.map { it.keyType }

    /** Extracted from [verify] so the decision is testable without a socket. */
    suspend fun decide(host: String, fingerprint: HostKeyFingerprint): Boolean {
        val decision = HostKeyGate.evaluate(host, fingerprint, store)
        lastDecision = decision
        return when (decision) {
            is HostKeyDecision.Proceed -> true
            is HostKeyDecision.Blocked -> false
            is HostKeyDecision.NeedsTrust -> {
                val accepted = onNeedsTrust(fingerprint)
                if (accepted) {
                    store.add(
                        KnownHostsEntry(host, fingerprint.keyType, fingerprint.publicKeyBase64)
                    )
                }
                accepted
            }
        }
    }
}
