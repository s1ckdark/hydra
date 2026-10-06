package com.hydra.android.core.network

import com.hydra.android.core.model.AgentStreamException
import org.junit.Assert.*
import org.junit.Test

class AgentSseDecoderTest {
    @Test fun `decoder supports split UTF8 comments CRLF and multiline data`() {
        val parser = AgentSseDecoder()
        val events = "\uFEFF: comment\r\nevent: progress\r\ndata: {\"title\":\r\ndata: \"작업 중\"}\r\n\r\n".toByteArray().asSequence().mapNotNull(parser::feed).toList()
        assertEquals(1, events.size)
        assertEquals("progress", events.single().name)
        assertEquals("{\"title\":\n\"작업 중\"}", events.single().data)
    }

    @Test fun `EOF never dispatches a partial event`() {
        val parser = AgentSseDecoder()
        assertTrue("event: chat_result\ndata: {\"message\":\"partial\"}".toByteArray().asSequence().mapNotNull(parser::feed).toList().isEmpty())
        parser.finish()
        assertNull(parser.feed('\n'.code.toByte()))
    }

    @Test fun `oversized frames and malformed utf8 fail without reflecting input`() {
        val parser = AgentSseDecoder(32)
        try { "data: SECRET-${"x".repeat(40)}".toByteArray().forEach(parser::feed); fail("frame accepted") }
        catch (failure: AgentStreamException) { assertFalse(failure.message.contains("SECRET")) }
        val malformed = AgentSseDecoder()
        try { byteArrayOf(0xc3.toByte(), 0x28, 10).forEach(malformed::feed); fail("invalid UTF8 accepted") }
        catch (failure: AgentStreamException) { assertFalse(failure.serverConfirmed) }
    }
}
