package com.hydra.android.core.ssh

import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import kotlinx.coroutines.flow.first
import javax.inject.Inject

data class SshCredentials(val user: String, val port: Int, val privateKeyPem: String)

/**
 * Same shape as iOS `TerminalSession.defaultCredentials`: one imported key, the
 * sshUsername setting, port 22. A missing key is reported before dialing so the
 * user gets "no key stored" rather than an opaque handshake failure.
 */
class SshCredentialResolver @Inject constructor(
    private val secureStore: SecureStore,
    private val settings: SettingsSource,
) {
    suspend fun resolve(): SshCredentials {
        val pem = secureStore.getSshPrivateKey()?.trim().orEmpty()
        if (pem.isEmpty()) throw SshError.AuthFailed(SshError.NO_KEY)
        val user = settings.sshUsername.first().trim().ifEmpty { DEFAULT_USER }
        return SshCredentials(user = user, port = DEFAULT_PORT, privateKeyPem = pem)
    }

    private companion object {
        const val DEFAULT_USER = "root"
        const val DEFAULT_PORT = 22
    }
}
