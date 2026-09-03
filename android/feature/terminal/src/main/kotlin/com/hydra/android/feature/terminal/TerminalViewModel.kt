package com.hydra.android.feature.terminal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.ssh.HostKeyFingerprint
import com.hydra.android.core.ssh.KnownHostsStore
import com.hydra.android.core.ssh.SshAuth
import com.hydra.android.core.ssh.SshCredentialResolver
import com.hydra.android.core.ssh.SshjTransport
import com.hydra.android.core.ssh.TofuHostKeyVerifier
import com.termux.terminal.TerminalSession
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class TerminalUiState(
    val deviceName: String = "",
    val isConnecting: Boolean = true,
    val pendingHostKey: HostKeyFingerprint? = null,
    val error: String? = null,
)

@HiltViewModel
class TerminalViewModel @Inject constructor(
    private val devices: DevicesRepository,
    private val credentials: SshCredentialResolver,
    private val knownHosts: KnownHostsStore,
) : ViewModel() {

    private val _state = MutableStateFlow(TerminalUiState())
    val state: StateFlow<TerminalUiState> = _state.asStateFlow()

    /** Completed by [acceptHostKey] / [rejectHostKey]. */
    private var trustAnswer: CompletableDeferred<Boolean>? = null

    var session: TerminalSession? = null
        private set

    /**
     * Called from the transport's HostKeyVerifier, on its IO thread. Suspends
     * until the user answers the dialog.
     */
    suspend fun requestHostKeyTrust(fingerprint: HostKeyFingerprint): Boolean {
        val deferred = CompletableDeferred<Boolean>()
        trustAnswer = deferred
        _state.update { it.copy(pendingHostKey = fingerprint) }
        return deferred.await()
    }

    fun acceptHostKey() {
        trustAnswer?.complete(true)
        trustAnswer = null
        _state.update { it.copy(pendingHostKey = null) }
    }

    fun rejectHostKey() {
        trustAnswer?.complete(false)
        trustAnswer = null
        _state.update { it.copy(pendingHostKey = null) }
    }

    fun reportFailure(e: Throwable) {
        _state.update { it.copy(isConnecting = false, error = e.message) }
    }

    fun connect(deviceId: String) {
        if (session != null) return
        viewModelScope.launch {
            val device = devices.list().getOrNull()?.firstOrNull { it.id == deviceId }
            if (device == null) {
                reportFailure(IllegalStateException("디바이스를 찾을 수 없습니다"))
                return@launch
            }
            _state.update { it.copy(deviceName = device.displayName) }

            val creds = runCatching { credentials.resolve() }.getOrElse {
                reportFailure(it)
                return@launch
            }

            val transport = SshjTransport(
                verifierFactory = { onTrust -> TofuHostKeyVerifier(knownHosts, onTrust) },
                onNeedsTrust = { fingerprint -> requestHostKeyTrust(fingerprint) },
            )
            val s = TerminalSession(
                transport = transport,
                scope = viewModelScope,
                onTitleChanged = {},
                onBell = {},
                onCopyToClipboard = {},
                onPasteFromClipboard = {},
            )
            session = s

            val host = device.tailscaleIp.ifEmpty { device.hostname }
            runCatching {
                s.start(host, creds.port, creds.user, SshAuth.PrivateKey(creds.privateKeyPem))
            }.onFailure { reportFailure(it) }
                .onSuccess { _state.update { st -> st.copy(isConnecting = false) } }
        }
    }

    override fun onCleared() {
        session?.close()
        session = null
    }
}
