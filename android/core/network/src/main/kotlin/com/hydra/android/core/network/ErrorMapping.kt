package com.hydra.android.core.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import retrofit2.HttpException
import java.io.IOException

private val errorJson = Json { ignoreUnknownKeys = true }

/**
 * Runs a network call and returns Result instead of throwing. The dashboard
 * merges five independent sources, and a thrown exception would let the first
 * failure swallow the rest — failures have to be values here.
 */
suspend fun <T> apiCall(block: suspend () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (e: IOException) {
        Result.failure(ApiException(null, "서버에 연결할 수 없습니다"))
    } catch (e: HttpException) {
        Result.failure(ApiException(e.code(), e.toUserMessage()))
    }

/**
 * Mirrors iOS APIClient.swift:336 — the server reports failures as
 * {"error": "..."}; fall back to the status code when the body is not that.
 */
private fun HttpException.toUserMessage(): String {
    if (code() == 401) return "API 키가 유효하지 않습니다"
    val raw = runCatching { response()?.errorBody()?.string() }.getOrNull()
    val serverMessage = raw?.takeIf { it.isNotBlank() }?.let { body ->
        runCatching {
            errorJson.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
    }
    return serverMessage?.takeIf { it.isNotBlank() } ?: "서버 오류 (${code()})"
}
