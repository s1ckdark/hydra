package com.hydra.android.core.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeSecureStore(private var key: String?) : SecureStore {
    override fun getApiKey() = key
    override fun setApiKey(value: String) { key = value.ifEmpty { null } }

    var sshKey: String? = null
    override fun getSshPrivateKey() = sshKey
    override fun setSshPrivateKey(value: String) { sshKey = value.ifEmpty { null } }
}

class SettingsServerConfigProviderTest {

    @Test
    fun `uses deployed default before hydration without being ready`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        assertFalse(provider.isReady())
        assertEquals("http://100.125.85.81:8081", provider.baseUrl())
    }

    @Test
    fun `reflects the latest cached server url`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("http://100.1.2.3:8080")
        assertEquals("http://100.1.2.3:8080", provider.baseUrl())
    }

    @Test
    fun `cleared custom server stays blank instead of selecting the default`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore("custom-server-key"))
        provider.updateServerUrl("http://custom.example:8080")
        provider.updateServerUrl("   ")
        assertEquals("", provider.baseUrl())
        assertTrue(provider.isReady())
    }

    @Test
    fun `invalid stored server URL remains invalid instead of selecting the default`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore("custom-server-key"))
        provider.updateServerUrl("  incomplete-address  ")
        assertEquals("incomplete-address", provider.baseUrl())
        assertTrue(provider.isReady())
    }

    @Test
    fun `surrounding whitespace is trimmed off the server url`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("  http://1.2.3.4:8080  ")
        assertEquals("http://1.2.3.4:8080", provider.baseUrl())
    }

    @Test
    fun `existing stored localhost URL is preserved after hydration`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("http://localhost:8080")
        assertEquals("http://localhost:8080", provider.baseUrl())
        assertTrue(provider.isReady())
    }

    @Test
    fun `reads the api key from the secure store on every call`() {
        val store = FakeSecureStore(null)
        val provider = SettingsServerConfigProvider(store)
        assertNull(provider.apiKey())
        store.setApiKey("k1")
        assertEquals("k1", provider.apiKey())
    }
}
