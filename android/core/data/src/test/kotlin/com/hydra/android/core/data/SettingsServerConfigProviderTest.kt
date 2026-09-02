package com.hydra.android.core.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

private class FakeSecureStore(private var key: String?) : SecureStore {
    override fun getApiKey() = key
    override fun setApiKey(value: String) { key = value.ifEmpty { null } }
}

class SettingsServerConfigProviderTest {

    @Test
    fun `defaults to localhost before any settings emission arrives`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        assertEquals("http://localhost:8080", provider.baseUrl())
    }

    @Test
    fun `reflects the latest cached server url`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("http://100.1.2.3:8080")
        assertEquals("http://100.1.2.3:8080", provider.baseUrl())
    }

    @Test
    fun `blank server url falls back to the default rather than breaking requests`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("   ")
        assertEquals("http://localhost:8080", provider.baseUrl())
    }

    @Test
    fun `surrounding whitespace is trimmed off the server url`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("  http://1.2.3.4:8080  ")
        assertEquals("http://1.2.3.4:8080", provider.baseUrl())
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
