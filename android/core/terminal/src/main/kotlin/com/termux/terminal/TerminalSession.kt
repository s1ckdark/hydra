package com.termux.terminal

import com.hydra.android.core.ssh.SshAuth
import com.hydra.android.core.ssh.SshTransport
import com.hydra.android.core.terminal.HydraSessionClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Our replacement for Termux's `TerminalSession`, which is `final` and forks a
 * local pty through JNI. Same package and class name so the vendored
 * `TerminalView` links against it unmodified; it calls only `write`,
 * `writeCodePoint`, `getEmulator` and `updateSize`.
 *
 * Threading: `TerminalEmulator` is not thread-safe. Termux confines it to the
 * main thread via a Handler; we do the same by collecting the SSH output flow
 * on `Dispatchers.Main`, which is also where `TerminalView` reads it.
 */
class TerminalSession(
    private val transport: SshTransport,
    private val scope: CoroutineScope,
    onTitleChanged: (String?) -> Unit,
    onBell: () -> Unit,
    onCopyToClipboard: (String) -> Unit,
    onPasteFromClipboard: () -> Unit,
) : TerminalOutput() {

    var title: String? = null
        private set

    private val client = HydraSessionClient(
        onTitle = onTitleChanged,
        onBellRung = onBell,
        onCopy = onCopyToClipboard,
        onPaste = onPasteFromClipboard,
    )

    /**
     * Null until the view reports a size — `TerminalView` guards on this in 15
     * places, matching Termux's own contract.
     *
     * The Kotlin property accessor *is* the `getEmulator()` that the vendored
     * Java calls; declaring an explicit function too would clash on the same
     * JVM signature.
     */
    var emulator: TerminalEmulator? = null
        private set

    val sizeKnown: Boolean get() = emulator != null

    private var connected = false
    private var shellOpened = false

    /** Bytes that arrived before the emulator existed. */
    private val pending = ArrayList<ByteArray>()

    /** Cancelled by [close] so a closed session stops draining a dead transport. */
    private val outputJob: Job = transport.output
        .onEach { bytes -> deliver(bytes) }
        .launchIn(CoroutineScope(scope.coroutineContext + Dispatchers.Main))

    /** Starts the SSH connection. The shell waits for [updateSize]. */
    suspend fun start(host: String, port: Int, user: String, auth: SshAuth) {
        transport.connect(host, port, user, auth)
        connected = true
        openShellIfReady()
    }

    /**
     * Called by `TerminalView` on layout. The first call creates the emulator
     * and, if the connection is up, opens the shell at the real size.
     *
     * iOS opens the shell at a hardcoded 80x24 before layout and re-applies the
     * true size afterwards, which loses a resize landing before openShell
     * completes. Waiting for the size removes the window entirely.
     */
    fun updateSize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        val existing = emulator
        if (existing == null) {
            emulator = TerminalEmulator(
                this, columns, rows, cellWidthPixels, cellHeightPixels, TRANSCRIPT_ROWS, client,
            )
            flushPending()
            scope.launch { openShellIfReady() }
        } else {
            existing.resize(columns, rows, cellWidthPixels, cellHeightPixels)
            scope.launch { transport.resize(columns, rows) }
        }
    }

    private suspend fun openShellIfReady() {
        if (shellOpened || !connected) return
        val e = emulator ?: return
        shellOpened = true
        transport.openShell(TERM_TYPE, e.mColumns, e.mRows)
    }

    private fun deliver(bytes: ByteArray) {
        val e = emulator
        if (e == null) {
            // Losing the first prompt on a server that prints it once looks
            // exactly like a hang. Buffering is cheap; the failure is not.
            pending += bytes
        } else {
            e.append(bytes, bytes.size)
        }
    }

    private fun flushPending() {
        val e = emulator ?: return
        pending.forEach { e.append(it, it.size) }
        pending.clear()
    }

    // --- TerminalOutput ---

    override fun write(data: ByteArray, offset: Int, count: Int) {
        val slice = data.copyOfRange(offset, offset + count)
        scope.launch { transport.write(slice) }
    }

    fun writeCodePoint(prependEscape: Boolean, codePoint: Int) {
        val text = buildString {
            if (prependEscape) append('')
            appendCodePoint(codePoint)
        }
        write(text)
    }

    override fun titleChanged(oldTitle: String?, newTitle: String?) {
        title = newTitle
        client.onTitleChanged(this)
    }

    override fun onCopyTextToClipboard(text: String?) = client.onCopyTextToClipboard(this, text)

    override fun onPasteTextFromClipboard() = client.onPasteTextFromClipboard(this)

    override fun onBell() = client.onBell(this)

    override fun onColorsChanged() = client.onColorsChanged(this)

    fun close() {
        outputJob.cancel()
        transport.disconnect()
    }

    private companion object {
        const val TERM_TYPE = "xterm-256color"
        const val TRANSCRIPT_ROWS = 2000
    }
}
