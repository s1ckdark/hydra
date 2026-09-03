package com.hydra.android.core.terminal

import com.hydra.android.core.ssh.SshAuth
import com.hydra.android.core.ssh.SshState
import com.hydra.android.core.ssh.SshTransport
import com.termux.terminal.TerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeTransport : SshTransport {
    val outputFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)
    override val output = outputFlow
    override val state = MutableStateFlow<SshState>(SshState.Idle)

    var connected = false
    var shellArgs: Triple<String, Int, Int>? = null
    val writes = mutableListOf<ByteArray>()
    val resizes = mutableListOf<Pair<Int, Int>>()
    var disconnected = false

    override suspend fun connect(host: String, port: Int, user: String, auth: SshAuth) {
        connected = true
        state.value = SshState.Connected
    }

    override suspend fun openShell(termType: String, cols: Int, rows: Int) {
        shellArgs = Triple(termType, cols, rows)
    }

    override suspend fun write(data: ByteArray) { writes += data }

    override suspend fun resize(cols: Int, rows: Int) { resizes += cols to rows }

    override fun disconnect() { disconnected = true }
}

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalSessionTest {

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    /**
     * The session's output collector lives for the life of its scope, so every
     * test must `close()` the session before returning — otherwise `runTest`
     * waits on the collector forever. Production does the same from
     * `onCleared`, so this is the real lifecycle, not a test-only shim.
     */
    private fun session(t: FakeTransport, scope: TestScope) = TerminalSession(
        transport = t,
        scope = scope,
        onTitleChanged = {},
        onBell = {},
        onCopyToClipboard = {},
        onPasteFromClipboard = {},
    )

    @Test
    fun `no emulator exists before the view reports a size`() = runTest {
        val s = session(FakeTransport(), this)
        assertNull(s.emulator)
        assertFalse(s.sizeKnown)

        s.close()
    }

    @Test
    fun `updateSize creates the emulator with those dimensions`() = runTest {
        val s = session(FakeTransport(), this)
        s.updateSize(100, 40, 10, 20)
        assertNotNull(s.emulator)
        assertEquals(100, s.emulator!!.mColumns)
        assertEquals(40, s.emulator!!.mRows)
        assertTrue(s.sizeKnown)

        s.close()
    }

    @Test
    fun `the shell opens only after both the connect and the first sizing`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)

        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        advanceUntilIdle()
        assertNull("shell must wait for a size", t.shellArgs)

        s.updateSize(100, 40, 10, 20)
        advanceUntilIdle()
        assertEquals(Triple("xterm-256color", 100, 40), t.shellArgs)

        s.close()
    }

    @Test
    fun `sizing before connecting still opens the shell once connected`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)

        s.updateSize(90, 30, 10, 20)
        advanceUntilIdle()
        assertNull(t.shellArgs)

        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        advanceUntilIdle()
        assertEquals(Triple("xterm-256color", 90, 30), t.shellArgs)

        s.close()
    }

    @Test
    fun `the shell is opened once, and later sizings resize instead`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        s.updateSize(100, 40, 10, 20)
        advanceUntilIdle()
        s.updateSize(120, 50, 10, 20)
        advanceUntilIdle()

        assertEquals(Triple("xterm-256color", 100, 40), t.shellArgs)
        assertEquals(listOf(120 to 50), t.resizes)

        s.close()
    }

    @Test
    fun `output arriving before the emulator exists is buffered and replayed`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        advanceUntilIdle()

        t.outputFlow.emit("hello".toByteArray())
        advanceUntilIdle()

        s.updateSize(80, 24, 10, 20)
        advanceUntilIdle()

        val screen = s.emulator!!.screen.getSelectedText(0, 0, 4, 0)
        assertEquals("hello", screen)

        s.close()
    }

    @Test
    fun `output arriving after the emulator exists lands directly`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        s.updateSize(80, 24, 10, 20)
        advanceUntilIdle()

        t.outputFlow.emit("world".toByteArray())
        advanceUntilIdle()

        assertEquals("world", s.emulator!!.screen.getSelectedText(0, 0, 4, 0))

        s.close()
    }

    @Test
    fun `write forwards bytes to the transport`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.write("ls\n".toByteArray(), 0, 3)
        advanceUntilIdle()
        assertArrayEquals("ls\n".toByteArray(), t.writes.single())

        s.close()
    }

    @Test
    fun `close disconnects the transport`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.close()
        assertTrue(t.disconnected)
    }
}
