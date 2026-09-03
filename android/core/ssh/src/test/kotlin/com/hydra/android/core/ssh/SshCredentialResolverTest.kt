package com.hydra.android.core.ssh

import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Backing fields are deliberately not named `apiKey`/`sshPrivateKey`: a Kotlin
// property named `apiKey` generates getApiKey()/setApiKey() accessors that clash
// with the interface methods of the same JVM signature.
private class FakeSecureStore(
    private var storedApiKey: String? = null,
    private var storedSshKey: String? = null,
) : SecureStore {
    override fun getApiKey() = storedApiKey
    override fun setApiKey(value: String) { storedApiKey = value.ifEmpty { null } }
    override fun getSshPrivateKey() = storedSshKey
    override fun setSshPrivateKey(value: String) { storedSshKey = value.ifEmpty { null } }
}

private class FakeSettings(username: String = "root") : SettingsSource {
    override val serverUrl = MutableStateFlow("http://localhost:8080")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(false)
    override val sshUsername = MutableStateFlow(username)
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
    override suspend fun setSshUsername(value: String) { sshUsername.value = value }
}

class SshCredentialResolverTest {

    @Test
    fun `resolves the stored key, username and default port`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(storedSshKey = "PEMBODY"), FakeSettings("dave"))
        val creds = r.resolve()
        assertEquals("dave", creds.user)
        assertEquals(22, creds.port)
        assertEquals("PEMBODY", creds.privateKeyPem)
    }

    @Test
    fun `a missing key fails before dialing, with an actionable message`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(storedSshKey = null), FakeSettings())
        val e = runCatching { r.resolve() }.exceptionOrNull()
        assertTrue(e is SshError.AuthFailed)
        assertEquals("SSH 키가 저장되어 있지 않습니다", e!!.message)
    }

    @Test
    fun `a blank stored key counts as missing`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(storedSshKey = "   "), FakeSettings())
        assertTrue(runCatching { r.resolve() }.exceptionOrNull() is SshError.AuthFailed)
    }

    @Test
    fun `a blank username falls back to root`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(storedSshKey = "PEM"), FakeSettings(""))
        assertEquals("root", r.resolve().user)
    }
}
