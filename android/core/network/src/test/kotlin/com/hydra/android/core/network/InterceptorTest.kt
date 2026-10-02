package com.hydra.android.core.network

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue

private class FakeConfig(var url: String, var key: String?) : ServerConfigProvider {
    override fun baseUrl() = url
    override fun apiKey() = key
}

class InterceptorTest {
    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() = server.shutdown()

    @Test
    fun `base url interceptor rewrites host and port from current config`() {
        val config = FakeConfig(server.url("/").toString().trimEnd('/'), null)
        val client = OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config)).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(
            Request.Builder().url("http://placeholder.invalid/api/devices").build()
        ).execute().close()

        assertEquals("/api/devices", server.takeRequest().path)
    }

    @Test
    fun `base url interceptor picks up a settings change without rebuilding the client`() {
        // The whole reason this interceptor exists: Retrofit pins its base URL
        // at construction, but the server address is editable at runtime.
        val second = MockWebServer().also { it.start() }
        try {
            val config = FakeConfig(server.url("/").toString().trimEnd('/'), null)
            val client = OkHttpClient.Builder()
                .addInterceptor(BaseUrlInterceptor(config)).build()
            server.enqueue(MockResponse().setBody("{}"))
            second.enqueue(MockResponse().setBody("{}"))

            client.newCall(
                Request.Builder().url("http://placeholder.invalid/health").build()
            ).execute().close()
            config.url = second.url("/").toString().trimEnd('/')
            client.newCall(
                Request.Builder().url("http://placeholder.invalid/health").build()
            ).execute().close()

            assertEquals(1, server.requestCount)
            assertEquals(1, second.requestCount)
        } finally {
            second.shutdown()
        }
    }

    @Test
    fun `base url interceptor preserves the path and query`() {
        val config = FakeConfig(server.url("/").toString().trimEnd('/'), null)
        val client = OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config)).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(
            Request.Builder()
                .url("http://placeholder.invalid/api/devices?refresh=true").build()
        ).execute().close()

        assertEquals("/api/devices?refresh=true", server.takeRequest().path)
    }

    @Test
    fun `base url interceptor rejects an invalid configured URL before network dispatch`() {
        val config = FakeConfig("not a url", null)
        val client = OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config)).build()
        server.enqueue(MockResponse().setBody("{}"))

        val failure = runCatching {
            client.newCall(Request.Builder().url(server.url("/health")).build()).execute().close()
        }.exceptionOrNull()
        assertTrue(failure is java.io.IOException)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `clearing hydrated custom URL never reads its key or contacts a fallback server`() {
        val fallback = MockWebServer().also { it.start() }
        var configuredUrl = server.url("/").toString()
        var authReads = 0
        val config = object : ServerConfigProvider {
            override fun baseUrl() = configuredUrl
            override fun apiKey(): String { authReads++; return "custom-server-key" }
        }
        val client = OkHttpClient.Builder().addInterceptor(BaseUrlInterceptor(config))
            .addInterceptor(AuthInterceptor(config)).build()
        try {
            server.enqueue(MockResponse().setBody("{}"))
            client.newCall(Request.Builder().url(fallback.url("/health")).build()).execute().close()
            assertEquals("Bearer custom-server-key", server.takeRequest().getHeader("Authorization"))
            for (edited in listOf("", "   ", "incomplete-address")) {
                configuredUrl = edited
                authReads = 0
                val failure = runCatching {
                    client.newCall(Request.Builder().url(fallback.url("/health")).build()).execute().close()
                }.exceptionOrNull()
                assertTrue(failure is java.io.IOException)
                assertEquals(0, authReads)
                assertEquals(0, fallback.requestCount)
                assertEquals(1, server.requestCount)
            }
        } finally { fallback.shutdown() }
    }

    @Test
    fun `auth interceptor omits the header entirely when no key is stored`() {
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", null))).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder().url(server.url("/health")).build())
            .execute().close()

        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `auth interceptor omits the header when the key is blank`() {
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", "  "))).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder().url(server.url("/health")).build())
            .execute().close()

        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `auth interceptor sends a bearer token when a key is stored`() {
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", "secret123"))).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder().url(server.url("/health")).build())
            .execute().close()

        assertEquals("Bearer secret123", server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `auth interceptor authenticates GET too, unlike iOS`() {
        // iOS's private get<T> never calls applyAuth (APIClient.swift:300-304),
        // so iOS sends no token on GET. Android authenticates every request.
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", "k"))).build()
        server.enqueue(MockResponse().setBody("[]"))

        client.newCall(
            Request.Builder().url(server.url("/api/devices")).get().build()
        ).execute().close()

        val recorded = server.takeRequest()
        assertEquals("GET", recorded.method)
        assertEquals("Bearer k", recorded.getHeader("Authorization"))
    }

    @Test
    fun `legacy calls await saved URL hydration before reading key or contacting default`() = runBlocking {
        val defaultServer = MockWebServer().also { it.start() }
        val hydrated = CompletableDeferred<Unit>()
        val config = object : ServerConfigProvider {
            override fun baseUrl() = if (hydrated.isCompleted) server.url("/").toString() else defaultServer.url("/").toString()
            override fun apiKey(): String { assertTrue(hydrated.isCompleted); return "custom-server-key" }
            override suspend fun awaitReady() { hydrated.await() }
        }
        try {
            server.enqueue(MockResponse().setBody("{}"))
            val client = OkHttpClient.Builder().addInterceptor(BaseUrlInterceptor(config)).addInterceptor(AuthInterceptor(config)).build()
            val result = async(Dispatchers.IO) { client.newCall(Request.Builder().url("http://placeholder.invalid/health").build()).execute().close() }
            delay(50)
            assertEquals(0, defaultServer.requestCount)
            assertEquals(0, server.requestCount)
            hydrated.complete(Unit)
            withTimeout(3_000) { result.await() }
            assertEquals(0, defaultServer.requestCount)
            assertEquals("Bearer custom-server-key", server.takeRequest().getHeader("Authorization"))
        } finally { defaultServer.shutdown() }
    }

    @Test
    fun `legacy auth uses captured credentials rather than rereading after origin change`() {
        val config = FakeConfig(server.url("/").toString(), "captured-key")
        server.enqueue(MockResponse().setBody("{}"))
        val client = OkHttpClient.Builder().addInterceptor(BaseUrlInterceptor(config))
            .addInterceptor { chain -> config.key = "replacement-key"; chain.proceed(chain.request()) }
            .addInterceptor(AuthInterceptor(config)).build()
        client.newCall(Request.Builder().url("http://placeholder.invalid/health").build()).execute().close()
        assertEquals("Bearer captured-key", server.takeRequest().getHeader("Authorization"))
    }
}
