package com.hydra.android.feature.settings

import androidx.lifecycle.ViewModel
import com.hydra.android.core.data.SecureStore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import javax.inject.Inject

data class SshKeyUiState(
    val pem: String = "",
    val hasStoredKey: Boolean = false,
    val message: String? = null,
)

@HiltViewModel
class SshKeyViewModel @Inject constructor(
    private val secureStore: SecureStore,
) : ViewModel() {

    private val _state = MutableStateFlow(
        SshKeyUiState(hasStoredKey = !secureStore.getSshPrivateKey().isNullOrBlank())
    )
    val state: StateFlow<SshKeyUiState> = _state.asStateFlow()

    fun onPemChange(value: String) {
        _state.update { it.copy(pem = value, message = null) }
    }

    fun save() {
        val pem = _state.value.pem.trim()
        if (pem.isEmpty()) {
            // Refuse rather than treating "empty" as "delete": silently wiping a
            // working key because the editor was blank is a bad surprise.
            _state.update { it.copy(message = "키 내용이 비어 있습니다") }
            return
        }
        secureStore.setSshPrivateKey(pem)
        _state.update { it.copy(pem = pem, hasStoredKey = true, message = "저장됨") }
    }

    fun delete() {
        secureStore.setSshPrivateKey("")
        _state.update { SshKeyUiState(pem = "", hasStoredKey = false, message = "삭제됨") }
    }
}
