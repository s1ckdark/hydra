package com.hydra.android.core.ssh

sealed interface HostKeyDecision {
    data object Proceed : HostKeyDecision
    data class NeedsTrust(val sha256: String) : HostKeyDecision
    data object Blocked : HostKeyDecision
}

/**
 * Trust-on-first-use gate. A MISMATCH is blocked outright rather than offered
 * as a "trust anyway" button: a changed host key is the exact signature of a
 * machine-in-the-middle, and a dialog trains the user to click through it.
 */
object HostKeyGate {
    fun evaluate(
        host: String,
        fingerprint: HostKeyFingerprint?,
        store: KnownHostsStore,
    ): HostKeyDecision {
        if (fingerprint == null) return HostKeyDecision.Blocked
        val entry = KnownHostsEntry(host, fingerprint.keyType, fingerprint.publicKeyBase64)
        return when (store.check(entry)) {
            KnownHostsCheck.MATCH -> HostKeyDecision.Proceed
            KnownHostsCheck.UNKNOWN -> HostKeyDecision.NeedsTrust(fingerprint.sha256)
            KnownHostsCheck.MISMATCH -> HostKeyDecision.Blocked
        }
    }
}
