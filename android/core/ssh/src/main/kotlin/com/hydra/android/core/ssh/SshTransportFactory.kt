package com.hydra.android.core.ssh

/**
 * Builds a transport for one terminal session.
 *
 * Exists so the terminal ViewModel does not name a concrete transport: without
 * this seam the sshj implementation is welded in, and the wiring between our
 * session and the vendored TerminalView cannot be exercised without a real SSH
 * server. `onNeedsTrust` is passed per-session because the trust prompt belongs
 * to the screen that is connecting.
 */
fun interface SshTransportFactory {
    fun create(onNeedsTrust: suspend (HostKeyFingerprint) -> Boolean): SshTransport
}

/** The production factory: sshj plus TOFU against the shared known_hosts store. */
class SshjTransportFactory(
    private val knownHosts: KnownHostsStore,
) : SshTransportFactory {
    override fun create(onNeedsTrust: suspend (HostKeyFingerprint) -> Boolean): SshTransport =
        SshjTransport(
            verifierFactory = { onTrust -> TofuHostKeyVerifier(knownHosts, onTrust) },
            onNeedsTrust = onNeedsTrust,
        )
}
