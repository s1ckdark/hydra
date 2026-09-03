package com.hydra.android.feature.settings

import app.cash.turbine.test
import com.hydra.android.core.data.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class KeyStore(
    private var storedApi: String? = null,
    private var storedSsh: String? = null,
) : SecureStore {
    val ssh: String? get() = storedSsh
    override fun getApiKey() = storedApi
    override fun setApiKey(value: String) { storedApi = value.ifEmpty { null } }
    override fun getSshPrivateKey() = storedSsh
    override fun setSshPrivateKey(value: String) { storedSsh = value.ifEmpty { null } }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SshKeyViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `reports whether a key is already stored`() = runTest {
        val vm = SshKeyViewModel(KeyStore(storedSsh = "PEM"))
        vm.state.test {
            assertTrue(awaitItem().hasStoredKey)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `reports no key when the store is empty`() = runTest {
        val vm = SshKeyViewModel(KeyStore())
        vm.state.test {
            assertFalse(awaitItem().hasStoredKey)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `saving writes the trimmed pem and reports success`() = runTest {
        val store = KeyStore()
        val vm = SshKeyViewModel(store)
        vm.onPemChange("  PEMBODY \n")
        vm.save()
        advanceUntilIdle()

        assertEquals("PEMBODY", store.ssh)
        vm.state.test {
            val s = awaitItem()
            assertTrue(s.hasStoredKey)
            assertEquals("저장됨", s.message)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `saving an empty pem is refused rather than clearing the stored key`() = runTest {
        val store = KeyStore(storedSsh = "EXISTING")
        val vm = SshKeyViewModel(store)
        vm.onPemChange("   ")
        vm.save()
        advanceUntilIdle()

        assertEquals("EXISTING", store.ssh)
        vm.state.test {
            assertEquals("키 내용이 비어 있습니다", awaitItem().message)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `delete clears the stored key and the editor`() = runTest {
        val store = KeyStore(storedSsh = "PEM")
        val vm = SshKeyViewModel(store)
        vm.delete()
        advanceUntilIdle()

        assertNull(store.ssh)
        vm.state.test {
            val s = awaitItem()
            assertFalse(s.hasStoredKey)
            assertEquals("", s.pem)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
