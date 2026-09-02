package com.hydra.android.feature.settings

import app.cash.turbine.test
import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsRepository
import com.hydra.android.core.data.SettingsSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeSecureStore : SecureStore {
    var key: String? = null
    override fun getApiKey() = key
    override fun setApiKey(value: String) { key = value.ifEmpty { null } }
}

private class FakeSettings(
    serverUrl: String = SettingsRepository.DEFAULT_SERVER_URL,
    aiInstruction: String = "",
    hideMobile: Boolean = false,
) : SettingsSource {
    override val serverUrl = MutableStateFlow(serverUrl)
    override val aiInstruction = MutableStateFlow(aiInstruction)
    override val hideMobileDevices = MutableStateFlow(hideMobile)
    override suspend fun setServerUrl(value: String) { this.serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { this.aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `exposes stored settings and the key already in the secure store`() = runTest {
        val store = FakeSecureStore().apply { key = "secret" }
        val vm = SettingsViewModel(
            FakeSettings(serverUrl = "http://1.2.3.4:8080", aiInstruction = "be terse"),
            store,
        )

        vm.state.test {
            awaitItem() // initial default before the flows combine
            val s = awaitItem()
            assertEquals("http://1.2.3.4:8080", s.serverUrl)
            assertEquals("secret", s.apiKey)
            assertEquals("be terse", s.aiInstruction)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `saving an api key writes through to the secure store`() = runTest {
        val store = FakeSecureStore()
        val vm = SettingsViewModel(FakeSettings(), store)
        vm.onApiKeyChange("k9")
        assertEquals("k9", store.key)
    }

    @Test
    fun `clearing the api key removes it from the secure store`() = runTest {
        val store = FakeSecureStore().apply { key = "old" }
        val vm = SettingsViewModel(FakeSettings(), store)
        vm.onApiKeyChange("")
        assertNull(store.key)
    }

    @Test
    fun `changing the server url writes through to settings`() = runTest {
        val settings = FakeSettings()
        val vm = SettingsViewModel(settings, FakeSecureStore())
        vm.onServerUrlChange("http://100.1.2.3:8080")
        advanceUntilIdle()
        assertEquals("http://100.1.2.3:8080", settings.serverUrl.value)
    }

    @Test
    fun `toggling hide-mobile writes through to settings`() = runTest {
        val settings = FakeSettings()
        val vm = SettingsViewModel(settings, FakeSecureStore())
        vm.onHideMobileChange(true)
        advanceUntilIdle()
        assertTrue(settings.hideMobileDevices.value)
    }

    @Test
    fun `changing the ai instruction writes through to settings`() = runTest {
        val settings = FakeSettings()
        val vm = SettingsViewModel(settings, FakeSecureStore())
        vm.onAiInstructionChange("answer in Korean")
        advanceUntilIdle()
        assertEquals("answer in Korean", settings.aiInstruction.value)
    }
}
