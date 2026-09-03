package com.hydra.android.core.terminal

import android.util.Log
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * The vendored `TerminalSessionClient` is a 16-method interface, mostly logging.
 * `setTerminalShellPid` is pty-specific and has no meaning over SSH — it is a
 * deliberate no-op, inherited from the vendored contract rather than an
 * oversight.
 */
class HydraSessionClient(
    private val onTitle: (String?) -> Unit,
    private val onBellRung: () -> Unit,
    private val onCopy: (String) -> Unit,
    private val onPaste: () -> Unit,
) : TerminalSessionClient {

    override fun onTextChanged(changedSession: TerminalSession) = Unit

    override fun onTitleChanged(changedSession: TerminalSession) = onTitle(changedSession.title)

    override fun onSessionFinished(finishedSession: TerminalSession) = Unit

    override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {
        text?.let(onCopy)
    }

    override fun onPasteTextFromClipboard(session: TerminalSession?) = onPaste()

    override fun onBell(session: TerminalSession) = onBellRung()

    override fun onColorsChanged(session: TerminalSession) = Unit

    override fun onTerminalCursorStateChange(state: Boolean) = Unit

    /** null = let TerminalEmulator keep its own default cursor style. */
    override fun getTerminalCursorStyle(): Int? = null

    /** No pty, no pid. Kept to satisfy the vendored interface. */
    override fun setTerminalShellPid(session: TerminalSession, pid: Int) = Unit

    override fun logError(tag: String?, message: String?) {
        Log.e(tag ?: TAG, message.orEmpty())
    }

    override fun logWarn(tag: String?, message: String?) {
        Log.w(tag ?: TAG, message.orEmpty())
    }

    override fun logInfo(tag: String?, message: String?) {
        Log.i(tag ?: TAG, message.orEmpty())
    }

    override fun logDebug(tag: String?, message: String?) {
        Log.d(tag ?: TAG, message.orEmpty())
    }

    override fun logVerbose(tag: String?, message: String?) {
        Log.v(tag ?: TAG, message.orEmpty())
    }

    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
        Log.e(tag ?: TAG, message.orEmpty(), e)
    }

    override fun logStackTrace(tag: String?, e: Exception?) {
        Log.e(tag ?: TAG, "", e)
    }

    private companion object {
        const val TAG = "HydraTerminal"
    }
}
