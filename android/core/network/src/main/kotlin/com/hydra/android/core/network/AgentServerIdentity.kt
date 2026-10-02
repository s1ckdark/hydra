package com.hydra.android.core.network

import com.hydra.android.core.model.AgentStreamException
import okhttp3.Authenticator
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Immutable request routing/auth snapshot. Its string representation never contains a key. */
class AgentServerIdentity private constructor(val baseUrl: String, internal val apiKey: String?) {
    companion object {
        fun capture(config: ServerConfigProvider, expectedServerUrl: String? = null): AgentServerIdentity {
            if (!config.isReady()) throw AgentStreamException("Server settings are still loading.")
            val origin = normalizeAgentServerUrl(config.baseUrl())
            if (expectedServerUrl != null && normalizeAgentServerUrl(expectedServerUrl) != origin) {
                throw AgentStreamException("Server changed. Reload this conversation or configuration.")
            }
            val key = config.apiKey()?.trim()?.takeIf(String::isNotEmpty)
            if (normalizeAgentServerUrl(config.baseUrl()) != origin) throw AgentStreamException("Server changed before the request was sent.")
            return AgentServerIdentity(origin, key)
        }
    }
}

/** Hydra APIs live at the origin root, matching the existing BaseUrlInterceptor. */
fun normalizeAgentServerUrl(value: String): String {
    val url = value.trim().toHttpUrlOrNull()
        ?: throw AgentStreamException("Enter a valid HTTP or HTTPS server URL.")
    if (url.username.isNotEmpty() || url.password.isNotEmpty() || url.query != null || url.fragment != null) {
        throw AgentStreamException("Server URL must not contain credentials, a query or a fragment.")
    }
    return url.newBuilder().encodedPath("/").build().toString()
}

/** A changed setting can reject a queued request, but can never retarget it. */
class PinnedAgentInterceptor(private val config: ServerConfigProvider) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val identity = request.tag(AgentServerIdentity::class.java)
            ?: throw IOException("Agent request has no pinned server.")
        val current = runCatching { normalizeAgentServerUrl(config.baseUrl()) }.getOrNull()
        if (!config.isReady() || current != identity.baseUrl) throw IOException("Server changed before the request was sent.")
        val origin = identity.baseUrl.toHttpUrlOrNull() ?: throw IOException("Invalid pinned server.")
        val builder = request.newBuilder().url(request.url.newBuilder()
            .scheme(origin.scheme).host(origin.host).port(origin.port).build())
            .removeHeader("Authorization")
        identity.apiKey?.let { builder.header("Authorization", "Bearer $it") }
        request.body?.let { builder.method(request.method, OneShotAgentBody(it)) }
        return chain.proceed(builder.build())
    }
}

/** Prevents OkHttp's automatic 408/503/421 follow-ups from replaying a mutation. */
private class OneShotAgentBody(private val delegate: RequestBody) : RequestBody() {
    override fun contentType() = delegate.contentType()
    override fun contentLength() = delegate.contentLength()
    override fun isOneShot() = true
    override fun writeTo(sink: BufferedSink) = delegate.writeTo(sink)
}

fun agentHttpClient(config: ServerConfigProvider): OkHttpClient = OkHttpClient.Builder()
    .addInterceptor(PinnedAgentInterceptor(config))
    .retryOnConnectionFailure(false)
    .followRedirects(false)
    .followSslRedirects(false)
    .authenticator(Authenticator.NONE)
    .proxyAuthenticator(Authenticator.NONE)
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(130, TimeUnit.SECONDS)
    .writeTimeout(30, TimeUnit.SECONDS)
    .build()
