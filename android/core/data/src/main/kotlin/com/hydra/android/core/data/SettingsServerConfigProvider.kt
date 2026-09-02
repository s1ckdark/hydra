package com.hydra.android.core.data

import com.hydra.android.core.network.ServerConfigProvider
import java.util.concurrent.atomic.AtomicReference

/**
 * OkHttp interceptors are not suspending, so they cannot await a DataStore
 * flow. This holds the last observed server URL in an atomic cell that a
 * long-lived collector (started in DataModule) keeps current.
 */
class SettingsServerConfigProvider(
    private val secureStore: SecureStore,
) : ServerConfigProvider {

    private val cached = AtomicReference(SettingsRepository.DEFAULT_SERVER_URL)

    fun updateServerUrl(value: String) {
        cached.set(value.trim().ifEmpty { SettingsRepository.DEFAULT_SERVER_URL })
    }

    override fun baseUrl(): String = cached.get()

    override fun apiKey(): String? = secureStore.getApiKey()
}
