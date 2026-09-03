package com.hydra.android.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SettingsUiState(
    val serverUrl: String = "",
    val apiKey: String = "",
    val aiInstruction: String = "",
    val hideMobileDevices: Boolean = false,
    val sshUsername: String = "",
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settings: SettingsSource,
    private val secureStore: SecureStore,
) : ViewModel() {

    /**
     * Every text field is backed by a local mirror rather than by the stored
     * flow it persists to.
     *
     * Rendering a field directly from DataStore makes each keystroke an async
     * round trip: the field shows a value one write behind, the next keystroke
     * is computed from that stale value, and characters silently disappear
     * when someone types quickly. The mirror updates synchronously and the
     * write is a side effect.
     *
     * The api key is already local by nature — it lives in the Keystore, which
     * has no flow at all.
     */
    private val serverUrlInput = MutableStateFlow("")
    private val aiInstructionInput = MutableStateFlow("")
    private val sshUsernameInput = MutableStateFlow("")
    private val apiKey = MutableStateFlow(secureStore.getApiKey().orEmpty())

    /**
     * Set as soon as the user edits anything, so a slow seed cannot land on
     * top of what they already typed.
     */
    private var edited = false

    init {
        // Seed the mirrors once from what is persisted; after this the mirrors
        // are the source of truth for the fields.
        viewModelScope.launch {
            val storedUrl = settings.serverUrl.first()
            val storedInstruction = settings.aiInstruction.first()
            val storedSshUser = settings.sshUsername.first()
            if (!edited) {
                serverUrlInput.value = storedUrl
                aiInstructionInput.value = storedInstruction
                sshUsernameInput.value = storedSshUser
            }
        }
    }

    val state: StateFlow<SettingsUiState> = combine(
        serverUrlInput,
        apiKey,
        aiInstructionInput,
        settings.hideMobileDevices,
        sshUsernameInput,
    ) { url, key, instruction, hideMobile, sshUser ->
        SettingsUiState(url, key, instruction, hideMobile, sshUser)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState())

    fun onServerUrlChange(value: String) {
        edited = true
        serverUrlInput.value = value
        viewModelScope.launch { settings.setServerUrl(value) }
    }

    fun onApiKeyChange(value: String) {
        apiKey.value = value
        secureStore.setApiKey(value)
    }

    fun onAiInstructionChange(value: String) {
        edited = true
        aiInstructionInput.value = value
        viewModelScope.launch { settings.setAiInstruction(value) }
    }

    fun onSshUsernameChange(value: String) {
        edited = true
        sshUsernameInput.value = value
        viewModelScope.launch { settings.setSshUsername(value) }
    }

    fun onHideMobileChange(value: Boolean) {
        viewModelScope.launch { settings.setHideMobileDevices(value) }
    }
}
