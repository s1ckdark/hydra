package com.hydra.android.feature.terminal

import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.Device
import com.hydra.android.core.ssh.HostKeyFingerprint
import com.hydra.android.core.ssh.SshCredentialResolver
import com.hydra.android.core.ssh.SshTransportFactory
import com.hydra.android.core.ssh.SshError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
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

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    private val fp = HostKeyFingerprint("ssh-ed25519", "AAAAKEY", "SHA256:abc")

    /**
     * The behaviours under test — the trust prompt and failure reporting —
     * never reach these collaborators, so the stubs only need to exist.
     */
    private fun viewModel(): TerminalViewModel {
        val devices = object : DevicesRepository {
            override suspend fun list(): Result<List<Device>> = Result.success(emptyList())
        }
        val secureStore = object : SecureStore {
            override fun getApiKey(): String? = null
            override fun setApiKey(value: String) = Unit
            override fun getSshPrivateKey(): String = "PEM"
            override fun setSshPrivateKey(value: String) = Unit
        }
        val settings = object : SettingsSource {
            override val serverUrl = MutableStateFlow("")
            override val aiInstruction = MutableStateFlow("")
            override val hideMobileDevices = MutableStateFlow(false)
            override val sshUsername = MutableStateFlow("root")
            override suspend fun setServerUrl(value: String) = Unit
            override suspend fun setAiInstruction(value: String) = Unit
            override suspend fun setHideMobileDevices(value: Boolean) = Unit
            override suspend fun setSshUsername(value: String) = Unit
        }
        return TerminalViewModel(
            devices = devices,
            credentials = SshCredentialResolver(secureStore, settings),
            transports = SshTransportFactory { throw UnsupportedOperationException() },
        )
    }

    /** Drives the suspend callback the transport's verifier would call. */
    private fun TestScope.launchTrust(vm: TerminalViewModel, answer: CompletableDeferred<Boolean>) {
        launch { answer.complete(vm.requestHostKeyTrust(fp)) }
    }

    @Test
    fun `a trust request surfaces the fingerprint to the UI`() = runTest {
        val vm = viewModel()
        val answer = CompletableDeferred<Boolean>()
        launchTrust(vm, answer)
        advanceUntilIdle()

        assertEquals("SHA256:abc", vm.state.value.pendingHostKey?.sha256)
        vm.rejectHostKey()
        advanceUntilIdle()
    }

    @Test
    fun `accepting the prompt answers true and clears it`() = runTest {
        val vm = viewModel()
        val answer = CompletableDeferred<Boolean>()
        launchTrust(vm, answer)
        advanceUntilIdle()

        vm.acceptHostKey()
        advanceUntilIdle()

        assertTrue(answer.await())
        assertNull(vm.state.value.pendingHostKey)
    }

    @Test
    fun `cancelling the prompt answers false and clears it`() = runTest {
        val vm = viewModel()
        val answer = CompletableDeferred<Boolean>()
        launchTrust(vm, answer)
        advanceUntilIdle()

        vm.rejectHostKey()
        advanceUntilIdle()

        assertEquals(false, answer.await())
        assertNull(vm.state.value.pendingHostKey)
    }

    @Test
    fun `a host key mismatch is shown as the disconnect reason`() = runTest {
        val vm = viewModel()
        vm.reportFailure(SshError.HostKeyMismatch())
        assertEquals(
            "호스트 키가 저장된 값과 다릅니다 — 연결을 차단했습니다",
            vm.state.value.error,
        )
    }

    @Test
    fun `a missing key is reported before any connection attempt`() = runTest {
        val vm = viewModel()
        vm.reportFailure(SshError.AuthFailed(SshError.NO_KEY))
        assertEquals("SSH 키가 저장되어 있지 않습니다", vm.state.value.error)
    }
}
