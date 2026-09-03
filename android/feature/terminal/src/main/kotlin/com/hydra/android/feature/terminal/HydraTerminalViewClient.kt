package com.hydra.android.feature.terminal

import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient

/**
 * The vendored `TerminalViewClient` is a 22-method interface. The key and
 * code-point hooks return false so `TerminalView` keeps its own default
 * handling; we only claim the soft-keyboard tap and the pinch-to-zoom scale.
 */
class HydraTerminalViewClient(
    private val view: () -> TerminalView?,
) : TerminalViewClient {

    private var fontSize = DEFAULT_FONT_SIZE

    override fun onScale(scale: Float): Float {
        if (scale < 0.9f || scale > 1.1f) {
            val next = (fontSize * scale).toInt().coerceIn(MIN_FONT_SIZE, MAX_FONT_SIZE)
            fontSize = next
            view()?.setTextSize(next)
            return 1.0f
        }
        return scale
    }

    /** Tapping the terminal should raise the soft keyboard. */
    override fun onSingleTapUp(e: MotionEvent) {
        view()?.requestFocus()
    }

    override fun shouldBackButtonBeMappedToEscape(): Boolean = false

    override fun shouldEnforceCharBasedInput(): Boolean = true

    override fun shouldUseCtrlSpaceWorkaround(): Boolean = false

    override fun isTerminalViewSelected(): Boolean = true

    override fun copyModeChanged(copyMode: Boolean) = Unit

    override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession): Boolean = false

    override fun onKeyUp(keyCode: Int, e: KeyEvent): Boolean = false

    override fun onLongPress(event: MotionEvent): Boolean = false

    // No hardware modifier row in this UI; the soft keyboard supplies them.
    override fun readControlKey(): Boolean = false

    override fun readAltKey(): Boolean = false

    override fun readShiftKey(): Boolean = false

    override fun readFnKey(): Boolean = false

    override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession): Boolean =
        false

    override fun onEmulatorSet() = Unit

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
        const val TAG = "HydraTerminalView"
        const val DEFAULT_FONT_SIZE = 28
        const val MIN_FONT_SIZE = 14
        const val MAX_FONT_SIZE = 72
    }
}
