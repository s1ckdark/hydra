package com.hydra.android.core.network

import com.hydra.android.core.model.AgentStreamException
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal data class AgentServerEvent(val name: String, val data: String)

/** Byte-based framing handles split UTF-8, CR/LF, comments and multiline data. */
internal class AgentSseDecoder(private val maximumEventBytes: Int = 2 * 1024 * 1024) {
    private val line = ByteArrayOutputStream()
    private var name = ""
    private val data = mutableListOf<String>()
    private var eventBytes = 0
    private var skipLf = false
    private var firstLine = true

    fun feed(byte: Byte): AgentServerEvent? {
        val value = byte.toInt() and 0xff
        if (skipLf) { skipLf = false; if (value == 10) return null }
        if (++eventBytes > maximumEventBytes) throw AgentStreamException("The agent response exceeded the supported size.")
        if (value == 10 || value == 13) {
            skipLf = value == 13
            return processLine()
        }
        line.write(value)
        return null
    }

    /** EOF does not dispatch an unterminated event. */
    fun finish() { line.reset(); data.clear(); name = ""; eventBytes = 0 }

    private fun processLine(): AgentServerEvent? {
        var text = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(line.toByteArray())).toString()
        } catch (_: Exception) { throw AgentStreamException("The agent response contained invalid text.") }
        line.reset()
        if (firstLine) { firstLine = false; text = text.removePrefix("\uFEFF") }
        if (text.isEmpty()) {
            val event = if (data.isEmpty()) null else AgentServerEvent(name.ifEmpty { "message" }, data.joinToString("\n"))
            data.clear(); name = ""; eventBytes = 0
            return event
        }
        if (text.startsWith(":")) return null
        val separator = text.indexOf(':')
        val field = if (separator < 0) text else text.substring(0, separator)
        val content = if (separator < 0) "" else text.substring(separator + 1).removePrefix(" ")
        when (field) { "event" -> name = content; "data" -> data += content }
        return null
    }
}
