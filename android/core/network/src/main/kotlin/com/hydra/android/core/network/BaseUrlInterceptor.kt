package com.hydra.android.core.network

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.IOException

internal class CapturedServerAuth(val apiKey: String?)

/**
 * Retrofit fixes its base URL at construction, but the Hydra server address is
 * user-editable at runtime (iOS solves this with APIClient.reloadBaseURL()).
 * Retrofit is built against a placeholder base and this interceptor rewrites
 * scheme/host/port from the current config on every request, so changing the
 * server in Settings needs no object-graph rebuild.
 *
 * An unparseable/blank configured URL fails before auth or network dispatch.
 * Editing a server address must never redirect its key to a fallback server.
 */
class BaseUrlInterceptor(private val config: ServerConfigProvider) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        try { runBlocking { withTimeout(10_000) { config.awaitReady() } } }
        catch (_: Exception) { throw IOException("Server settings are unavailable.") }
        val configuredValue = config.baseUrl()
        val configured = configuredValue.trim().toHttpUrlOrNull()
            ?: throw IOException("Enter a valid HTTP or HTTPS server URL.")
        val key = config.apiKey()
        if (config.baseUrl() != configuredValue) throw IOException("Server changed before the request was sent.")
        val rewritten = request.url.newBuilder()
            .scheme(configured.scheme)
            .host(configured.host)
            .port(configured.port)
            .build()
        return chain.proceed(request.newBuilder().url(rewritten).tag(CapturedServerAuth::class.java, CapturedServerAuth(key)).build())
    }
}
