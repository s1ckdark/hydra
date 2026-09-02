package com.hydra.android.core.network

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Adds `Authorization: Bearer <key>` when a key is stored, and nothing at all
 * when it is absent or blank — an empty header is not the same as no header.
 *
 * Note this applies to GET as well. iOS only authenticates POST/DELETE
 * (APIClient.swift:300-304 never calls applyAuth); sending the header on every
 * request is the intended Android behaviour.
 */
class AuthInterceptor(private val config: ServerConfigProvider) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val key = config.apiKey()?.trim().orEmpty()
        if (key.isEmpty()) return chain.proceed(chain.request())
        return chain.proceed(
            chain.request().newBuilder()
                .header("Authorization", "Bearer $key")
                .build()
        )
    }
}
