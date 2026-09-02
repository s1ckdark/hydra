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
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SettingsUiState(
    val serverUrl: String = "",
    val apiKey: String = "",
    val aiInstruction: String = "",
    val hideMobileDevices: Boolean = false,
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settings: SettingsSource,
    private val secureStore: SecureStore,
) : ViewModel() {

    // The key is not a Flow — it lives in the Keystore, read once and then
    // mirrored here so the text field stays a controlled component.
    private val apiKey = MutableStateFlow(secureStore.getApiKey().orEmpty())

    val state: StateFlow<SettingsUiState> = combine(
        settings.serverUrl,
        apiKey,
        settings.aiInstruction,
        settings.hideMobileDevices,
    ) { url, key, instruction, hideMobile ->
        SettingsUiState(url, key, instruction, hideMobile)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState())

    fun onServerUrlChange(value: String) {
        viewModelScope.launch { settings.setServerUrl(value) }
    }

    fun onApiKeyChange(value: String) {
        apiKey.value = value
        secureStore.setApiKey(value)
    }

    fun onAiInstructionChange(value: String) {
        viewModelScope.launch { settings.setAiInstruction(value) }
    }

    fun onHideMobileChange(value: Boolean) {
        viewModelScope.launch { settings.setHideMobileDevices(value) }
    }
}
