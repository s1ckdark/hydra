package com.hydra.android.core.ssh

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

sealed interface SshState {
    data object Idle : SshState
    data object Connecting : SshState
    data object Connected : SshState
    data class Disconnected(val reason: String?) : SshState
}

sealed interface SshAuth {
    data class PrivateKey(val pem: String) : SshAuth
}

/**
 * Mirrors iOS `SSHSession` (TerminalCore/Sources/SSHTransport/SSHSession.swift).
 * Implementations are single-use: once disconnected, build a new one.
 */
interface SshTransport {
    val output: Flow<ByteArray>
    val state: StateFlow<SshState>

    suspend fun connect(host: String, port: Int, user: String, auth: SshAuth)
    suspend fun openShell(termType: String, cols: Int, rows: Int)
    suspend fun write(data: ByteArray)
    suspend fun resize(cols: Int, rows: Int)
    fun disconnect()
}
