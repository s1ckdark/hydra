package com.hydra.android.core.network

import kotlinx.coroutines.test.runTest
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.IOException

class ErrorMappingTest {

    private fun http(status: Int, body: String) = HttpException(
        Response.error<Any>(status, body.toResponseBody("application/json".toMediaType()))
    )

    @Test
    fun `io failure maps to a connection message`() = runTest {
        val result = apiCall<Unit> { throw IOException("boom") }
        val e = result.exceptionOrNull() as ApiException
        assertEquals("서버에 연결할 수 없습니다", e.message)
        assertNull(e.status)
    }

    @Test
    fun `401 maps to an invalid key message`() = runTest {
        val result = apiCall<Unit> { throw http(401, """{"error":"nope"}""") }
        val e = result.exceptionOrNull() as ApiException
        assertEquals("API 키가 유효하지 않습니다", e.message)
        assertEquals(401, e.status)
    }

    @Test
    fun `other http errors surface the server error body`() = runTest {
        val result = apiCall<Unit> { throw http(500, """{"error":"device unreachable"}""") }
        val e = result.exceptionOrNull() as ApiException
        assertEquals("device unreachable", e.message)
        assertEquals(500, e.status)
    }

    @Test
    fun `unparseable error body falls back to the status code`() = runTest {
        val result = apiCall<Unit> { throw http(503, "<html>gateway</html>") }
        val e = result.exceptionOrNull() as ApiException
        assertTrue(e.message.contains("503"))
    }

    @Test
    fun `an error body with a blank error field falls back to the status code`() = runTest {
        val result = apiCall<Unit> { throw http(502, """{"error":""}""") }
        val e = result.exceptionOrNull() as ApiException
        assertTrue(e.message.contains("502"))
    }

    @Test
    fun `success passes the value through`() = runTest {
        assertEquals("ok", apiCall { "ok" }.getOrNull())
    }
}
