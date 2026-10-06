package com.hydra.android.core.data

import com.hydra.android.core.network.ServerConfigProvider
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.io.IOException

/**
 * OkHttp interceptors are not suspending, so they cannot await a DataStore
 * flow. This holds the last observed server URL in an atomic cell that a
 * long-lived collector (started in DataModule) keeps current.
 */
class SettingsServerConfigProvider(
    private val secureStore: SecureStore,
) : ServerConfigProvider {

    private val cached = AtomicReference(SettingsRepository.DEFAULT_SERVER_URL)
    private val ready = CompletableDeferred<Unit>()

    fun updateServerUrl(value: String) {
        // The repository supplies the default only when no value was stored.
        // A cleared/partially edited URL must remain invalid, not redirect a
        // custom server's existing credential to the default server.
        cached.set(value.trim())
        ready.complete(Unit)
    }

    fun failReadiness() { ready.completeExceptionally(IOException("Server settings could not be loaded.")) }
    override fun isReady(): Boolean = ready.isCompleted && !ready.isCancelled
    override suspend fun awaitReady() { withTimeout(10_000) { ready.await() } }

    override fun baseUrl(): String = cached.get()

    override fun apiKey(): String? = secureStore.getApiKey()
}
