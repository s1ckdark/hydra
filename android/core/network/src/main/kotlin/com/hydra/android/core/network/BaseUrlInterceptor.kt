package com.hydra.android.core.network

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Retrofit fixes its base URL at construction, but the Hydra server address is
 * user-editable at runtime (iOS solves this with APIClient.reloadBaseURL()).
 * Retrofit is built against a placeholder base and this interceptor rewrites
 * scheme/host/port from the current config on every request, so changing the
 * server in Settings needs no object-graph rebuild.
 *
 * An unparseable configured URL leaves the request untouched rather than
 * failing it — the caller sees a normal connection error, not a crash.
 */
class BaseUrlInterceptor(private val config: ServerConfigProvider) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val configured = config.baseUrl().trim().toHttpUrlOrNull()
            ?: return chain.proceed(request)
        val rewritten = request.url.newBuilder()
            .scheme(configured.scheme)
            .host(configured.host)
            .port(configured.port)
            .build()
        return chain.proceed(request.newBuilder().url(rewritten).build())
    }
}
