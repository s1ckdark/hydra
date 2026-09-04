package com.hydra.android.feature.terminal

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.Device
import com.hydra.android.core.ssh.HostKeyFingerprint
import com.hydra.android.core.ssh.SshAuth
import com.hydra.android.core.ssh.SshCredentialResolver
import com.hydra.android.core.ssh.SshState
import com.hydra.android.core.ssh.SshTransport
import com.hydra.android.core.ssh.SshTransportFactory
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private val TEST_DEVICE = Device(
    id = "d1",
    name = "test-host",
    hostname = "test-host",
    status = "online",
    lastSeen = T0,
    sshEnabled = true,
    tailscaleIp = "100.0.0.1",
)

/**
 * A transport that never touches a socket. `emit` pushes bytes as if the remote
 * shell had written them, which is all the vendored emulator needs.
 */
private class ScriptedTransport : SshTransport {
    // replay = 1 so a byte emitted before the session's collector has actually
    // started is still delivered. Without it this double would be testing
    // SharedFlow subscription timing rather than anything about the app.
    private val out = MutableSharedFlow<ByteArray>(replay = 1, extraBufferCapacity = 64)
    override val output = out
    override val state = MutableStateFlow<SshState>(SshState.Idle)

    var shellArgs: Triple<String, Int, Int>? = null
        private set
    var connectCount = 0
        private set

    override suspend fun connect(host: String, port: Int, user: String, auth: SshAuth) {
        connectCount++
        state.value = SshState.Connected
    }

    override suspend fun openShell(termType: String, cols: Int, rows: Int) {
        shellArgs = Triple(termType, cols, rows)
    }

    override suspend fun write(data: ByteArray) = Unit
    override suspend fun resize(cols: Int, rows: Int) = Unit
    override fun disconnect() = Unit

    suspend fun emit(text: String) = out.emit(text.toByteArray())
}

private fun secureStore(sshKey: String?) = object : SecureStore {
    override fun getApiKey(): String? = null
    override fun setApiKey(value: String) = Unit
    override fun getSshPrivateKey() = sshKey
    override fun setSshPrivateKey(value: String) = Unit
}

private fun settings() = object : SettingsSource {
    override val serverUrl = MutableStateFlow("")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(false)
    override val sshUsername = MutableStateFlow("tester")
    override suspend fun setServerUrl(value: String) = Unit
    override suspend fun setAiInstruction(value: String) = Unit
    override suspend fun setHideMobileDevices(value: Boolean) = Unit
    override suspend fun setSshUsername(value: String) = Unit
}

private fun devices() = object : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = Result.success(listOf(TEST_DEVICE))
}

private fun viewModel(
    transport: SshTransport,
    sshKey: String? = "PEM",
) = TerminalViewModel(
    devices = devices(),
    credentials = SshCredentialResolver(secureStore(sshKey), settings()),
    transports = SshTransportFactory { transport },
)

/**
 * Regression cover for the wiring between our TerminalSession and the vendored
 * Termux TerminalView. All three failures this pins down were invisible to the
 * unit tests — those call `updateSize` themselves and so never exercise the
 * view's own undocumented initialisation order — and all three presented as a
 * black screen with no error.
 *
 * The transport is scripted, so nothing here needs SSH, a key, or a server.
 */
class TerminalScreenTest {

    @get:Rule
    val compose = createComposeRule()

    private fun launch(vm: TerminalViewModel) {
        compose.setContent {
            TerminalScreen(deviceId = "d1", onClose = {}, viewModel = vm)
        }
        compose.waitForIdle()
    }

    /** The emulator exists only after the view has laid out and sized itself. */
    private fun awaitEmulator(vm: TerminalViewModel, timeoutMs: Long = 5_000) {
        compose.waitUntil(timeoutMs) { vm.session.value?.emulator != null }
    }

    private fun screenText(vm: TerminalViewModel): String {
        val emulator = requireNotNull(vm.session.value?.emulator)
        return emulator.screen.getSelectedText(0, 0, emulator.mColumns - 1, 0).trim()
    }

    @Test
    fun theViewSizesItselfAndTheShellOpensWithRealDimensions() {
        // Guards the setTextSize omission: without it TerminalView's renderer is
        // null, updateSize bails early, and no emulator is ever created.
        val transport = ScriptedTransport()
        val vm = viewModel(transport)
        launch(vm)
        awaitEmulator(vm)

        val args = requireNotNull(transport.shellArgs)
        assertEquals("xterm-256color", args.first)
        assertTrue("expected real columns, got ${args.second}", args.second > 4)
        assertTrue("expected real rows, got ${args.third}", args.third > 4)
    }

    @Test
    fun remoteOutputReachesTheEmulatorScreen() {
        // Guards the session attach: `session` must be observable state, or the
        // AndroidView update block never runs and nothing is ever attached.
        val transport = ScriptedTransport()
        val vm = viewModel(transport)
        launch(vm)
        awaitEmulator(vm)

        runBlocking { transport.emit("HELLO-FROM-REMOTE") }
        compose.waitUntil(5_000) { screenText(vm).contains("HELLO-FROM-REMOTE") }

        assertTrue(screenText(vm).contains("HELLO-FROM-REMOTE"))
    }

    @Test
    fun outputArrivingBeforeTheFirstSizingIsNotLost() {
        // A server that prints its prompt once would otherwise look like a hang.
        // The byte is emitted before the screen is ever composed, so it can only
        // reach the display via the session's pending buffer.
        val transport = ScriptedTransport()
        val vm = viewModel(transport)
        vm.connect("d1")
        runBlocking { transport.emit("EARLY-PROMPT") }

        launch(vm)
        awaitEmulator(vm)
        compose.waitUntil(5_000) { screenText(vm).contains("EARLY-PROMPT") }

        assertTrue(screenText(vm).contains("EARLY-PROMPT"))
    }

    @Test
    fun theTerminalSurfaceIsOpaqueAndDark() {
        // The vendored renderer paints only cells that have content; everything
        // else shows the view background. With no opaque dark background the
        // light-on-dark scheme puts white text on Compose's light surface and
        // the shell is invisible — text present, nothing readable. Only a pixel
        // assertion catches that; the screen-buffer checks above cannot.
        val vm = viewModel(ScriptedTransport())
        launch(vm)
        awaitEmulator(vm)

        val image = compose.onNodeWithTag(TERMINAL_VIEW_TAG).captureToImage().asAndroidBitmap()
        var dark = 0
        var sampled = 0
        var y = 0
        while (y < image.height) {
            var x = 0
            while (x < image.width) {
                val p = image.getPixel(x, y)
                val luma = ((p shr 16 and 0xFF) + (p shr 8 and 0xFF) + (p and 0xFF)) / 3
                if (luma < 60) dark++
                sampled++
                x += 8
            }
            y += 8
        }
        assertTrue(
            "terminal surface should be predominantly dark, was $dark/$sampled",
            dark * 100 / sampled > 80,
        )
    }

    @Test
    fun aMissingKeyIsReportedWithoutTouchingTheTransport() {
        val transport = ScriptedTransport()
        val vm = viewModel(transport, sshKey = null)
        launch(vm)

        compose.waitUntil(5_000) { vm.state.value.error != null }
        compose.onNodeWithText("SSH 키가 저장되어 있지 않습니다").assertIsDisplayed()
        assertEquals(0, transport.connectCount)
        assertNull(vm.session.value)
    }

    @Test
    fun theDeviceNameIsShownInTheAppBar() {
        val vm = viewModel(ScriptedTransport())
        launch(vm)
        compose.waitUntil(5_000) { vm.state.value.deviceName.isNotEmpty() }
        compose.onNodeWithText("test-host").assertIsDisplayed()
        assertNotNull(vm.session.value)
    }
}
