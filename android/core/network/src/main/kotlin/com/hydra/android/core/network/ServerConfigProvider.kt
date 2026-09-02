package com.hydra.android.core.network

/**
 * Live view of the user-editable server settings. Implemented in :core:data
 * over DataStore + the Keystore-backed secret store; the network layer reads
 * it on every request so a settings change takes effect immediately.
 */
interface ServerConfigProvider {
    fun baseUrl(): String
    fun apiKey(): String?
}
