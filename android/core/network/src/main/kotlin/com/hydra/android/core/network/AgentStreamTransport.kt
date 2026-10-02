package com.hydra.android.core.network

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.AgentRunSnapshot
import com.hydra.android.core.model.AgentStreamEvent
import com.hydra.android.core.model.AgentStreamException
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonArray
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.ResponseBody
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference

interface AgentStreamTransport {
    fun send(request: ChatRequest): Flow<AgentStreamEvent>
    fun execute(request: AgentExecuteRequest): Flow<AgentStreamEvent>
}

/** One HTTP request per collection. No transport or application fallback re-POST. */
class OkHttpAgentStreamTransport(
    private val client: OkHttpClient,
    private val config: ServerConfigProvider,
    private val json: Json,
) : AgentStreamTransport {
    override fun send(request: ChatRequest): Flow<AgentStreamEvent> = stream(
        "api/agent/chat", json.encodeToString(request), request.expectedServerUrl, execute = false,
    )
    override fun execute(request: AgentExecuteRequest): Flow<AgentStreamEvent> = stream(
        "api/agent/execute", json.encodeToString(request), request.expectedServerUrl, execute = true,
    )

    private fun stream(path: String, body: String, expected: String?, execute: Boolean): Flow<AgentStreamEvent> {
        // Capture a ready origin at API invocation, not later when a queued flow
        // starts collecting. Before hydration there is no trustworthy origin.
        val captured = if (config.isReady()) runCatching { AgentServerIdentity.capture(config, expected) } else null
        return callbackFlow {
            val activeCall = AtomicReference<Call?>()
            val worker = launch(Dispatchers.IO) {
                try {
                    withTimeout(10_000) { config.awaitReady() }
                    currentCoroutineContext().ensureActive()
                    val identity = captured?.getOrThrow() ?: AgentServerIdentity.capture(config, expected)
                    val call = client.newCall(Request.Builder()
                        .url(identity.baseUrl + path + "?stream=1")
                        .tag(AgentServerIdentity::class.java, identity)
                        .header("Accept", "text/event-stream")
                        .post(body.toRequestBody("application/json".toMediaType()))
                        .build())
                    activeCall.set(call)
                    currentCoroutineContext().ensureActive()
                    call.execute().use { response ->
                        val responseBody = response.body ?: throw AgentStreamException("The agent response was empty.")
                        if (!response.isSuccessful) {
                            val errorText = boundedBody(responseBody)
                            throw AgentStreamException(serverMessage(errorText) ?: "Server error (${response.code}).", serverConfirmed = true)
                        }
                        val type = response.header("Content-Type").orEmpty().substringBefore(';').trim().lowercase()
                        if (type == "application/json") {
                            // Older servers may answer this same POST with JSON.
                            send(decodeResult(boundedBody(responseBody), execute))
                        } else if (type == "text/event-stream") {
                            val parser = AgentSseDecoder()
                            val source = responseBody.source()
                            var finalReceived = false
                            while (!finalReceived && !source.exhausted()) {
                                currentCoroutineContext().ensureActive()
                                val event = parser.feed(source.readByte()) ?: continue
                                when (event.name) {
                                    "progress" -> send(AgentStreamEvent.Progress(json.decodeFromString<AgentRunSnapshot>(event.data)))
                                    "chat_result", "execute_result" -> {
                                        if (event.name != if (execute) "execute_result" else "chat_result") {
                                            throw AgentStreamException("The agent response contained an unexpected final result.")
                                        }
                                        send(decodeResult(event.data, execute)); finalReceived = true
                                    }
                                    "error" -> throw AgentStreamException(serverMessage(event.data) ?: "Agent request failed.", serverConfirmed = true)
                                }
                            }
                            parser.finish()
                            if (!finalReceived) throw AgentStreamException("The progress connection ended before the final result arrived.")
                        } else {
                            throw AgentStreamException("The server did not return an agent response.")
                        }
                    }
                    close()
                } catch (_: TimeoutCancellationException) {
                    close(AgentStreamException("Server settings could not be loaded in time."))
                } catch (cancelled: CancellationException) {
                    close(cancelled)
                } catch (failure: AgentStreamException) {
                    close(failure)
                } catch (_: IOException) {
                    close(AgentStreamException("The agent connection was interrupted. The execution outcome may be unknown."))
                } catch (_: Exception) {
                    close(AgentStreamException("The server returned an invalid agent response."))
                } finally {
                    activeCall.getAndSet(null)?.cancel()
                }
            }
            // This cleanup executes on collection cancellation even while the
            // worker is blocked inside a socket body read.
            awaitClose { activeCall.getAndSet(null)?.cancel(); worker.cancel() }
        }.buffer(Channel.RENDEZVOUS)
    }

    private fun decodeResult(body: String, execute: Boolean): AgentStreamEvent {
        if (execute) {
            if (json.parseToJsonElement(body).jsonObject["results"] !is JsonArray) {
                throw AgentStreamException("The agent response did not contain execution results.")
            }
            return AgentStreamEvent.ExecuteResult(json.decodeFromString<AgentExecuteResponse>(body))
        }
        return AgentStreamEvent.ChatResult(json.decodeFromString<ChatResponse>(body))
    }

    private fun boundedBody(body: ResponseBody): String {
        val source = body.source()
        val maximum = 2L * 1024 * 1024
        if (source.request(maximum + 1)) throw AgentStreamException("The agent response exceeded the supported size.")
        return source.readUtf8()
    }

    private fun serverMessage(body: String): String? = runCatching {
        json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content?.take(1024)?.takeIf { it.isNotBlank() }
    }.getOrNull()
}
