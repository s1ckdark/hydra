package com.hydra.android.core.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore("hydra_settings")

/**
 * The read/write surface ViewModels depend on. Exists so tests can substitute
 * a plain StateFlow-backed fake instead of standing up Android's DataStore.
 */
interface SettingsSource {
    val serverUrl: Flow<String>
    val aiInstruction: Flow<String>
    val hideMobileDevices: Flow<Boolean>
    val sshUsername: Flow<String>
    suspend fun setServerUrl(value: String)
    suspend fun setAiInstruction(value: String)
    suspend fun setHideMobileDevices(value: Boolean)
    suspend fun setSshUsername(value: String)
}

/**
 * Non-secret settings. The API key lives in [SecureStore] instead — see the
 * iOS split between UserDefaults and CredentialStore.
 */
class SettingsRepository(private val context: Context) : SettingsSource {

    override val serverUrl: Flow<String> =
        context.dataStore.data.map { it[SERVER_URL] ?: DEFAULT_SERVER_URL }

    override val aiInstruction: Flow<String> =
        context.dataStore.data.map { it[AI_INSTRUCTION] ?: "" }

    override val hideMobileDevices: Flow<Boolean> =
        context.dataStore.data.map { it[HIDE_MOBILE] ?: false }

    /**
     * v1 deliberately omitted this: "a settings row that controls nothing
     * invites bug reports". SSH arrives here, so the reasoning expires and the
     * setting returns.
     */
    override val sshUsername: Flow<String> =
        context.dataStore.data.map { it[SSH_USERNAME] ?: DEFAULT_SSH_USERNAME }

    override suspend fun setServerUrl(value: String) {
        context.dataStore.edit { it[SERVER_URL] = value }
    }

    override suspend fun setAiInstruction(value: String) {
        context.dataStore.edit { it[AI_INSTRUCTION] = value }
    }

    override suspend fun setHideMobileDevices(value: Boolean) {
        context.dataStore.edit { it[HIDE_MOBILE] = value }
    }

    override suspend fun setSshUsername(value: String) {
        context.dataStore.edit { it[SSH_USERNAME] = value }
    }

    companion object {
        const val DEFAULT_SERVER_URL = "http://localhost:8080"
        const val DEFAULT_SSH_USERNAME = "root"
        private val SERVER_URL = stringPreferencesKey("serverUrl")
        private val AI_INSTRUCTION = stringPreferencesKey("aiInstruction")
        private val HIDE_MOBILE = booleanPreferencesKey("hideMobileDevices")
        private val SSH_USERNAME = stringPreferencesKey("sshUsername")
    }
}
