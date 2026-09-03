package com.hydra.android.core.ssh

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.schmizz.sshj.AndroidConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.userauth.UserAuthException
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.Security
import java.util.concurrent.Executors

/**
 * The only SshTransport implementation. sshj is blocking, so everything runs on
 * a dedicated single-thread dispatcher — which is also the thread the
 * HostKeyVerifier may block on while the user answers the trust prompt.
 */
class SshjTransport(
    private val verifierFactory: (suspend (HostKeyFingerprint) -> Boolean) -> TofuHostKeyVerifier,
    private val onNeedsTrust: suspend (HostKeyFingerprint) -> Boolean,
) : SshTransport {

    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ssh-io").apply { isDaemon = true }
    }.asCoroutineDispatcher()
    private val scope = CoroutineScope(io + Job())

    private val _state = MutableStateFlow<SshState>(SshState.Idle)
    override val state: StateFlow<SshState> = _state.asStateFlow()

    private val _output = MutableSharedFlow<ByteArray>(
        replay = 0,
        extraBufferCapacity = 256,
        onBufferOverflow = BufferOverflow.SUSPEND,
    )
    override val output: Flow<ByteArray> = _output.asSharedFlow()

    private var client: SSHClient? = null
    private var session: Session? = null
    private var shell: Session.Shell? = null
    private var stdin: OutputStream? = null
    private var readJob: Job? = null

    override suspend fun connect(host: String, port: Int, user: String, auth: SshAuth) {
        withContext(io) {
            installBouncyCastle()
            _state.value = SshState.Connecting

            val ssh = SSHClient(AndroidConfig())
            val verifier = verifierFactory(onNeedsTrust)
            ssh.addHostKeyVerifier(verifier)
            ssh.connectTimeout = CONNECT_TIMEOUT_MS

            try {
                ssh.connect(host, port)
            } catch (e: IOException) {
                // A rejected host key surfaces here as a transport exception;
                // distinguish it so the user sees why rather than "unreachable".
                _state.value = SshState.Disconnected(null)
                throw if (verifier.lastDecision is HostKeyDecision.Blocked) {
                    SshError.HostKeyMismatch()
                } else {
                    SshError.Unreachable()
                }
            }

            try {
                val pem = (auth as SshAuth.PrivateKey).pem
                // loadKeys detects the format from the content itself, so the
                // key never touches disk.
                ssh.authPublickey(user, ssh.loadKeys(pem, null, null))
            } catch (e: UserAuthException) {
                runCatching { ssh.disconnect() }
                _state.value = SshState.Disconnected(SshError.AUTH_REJECTED)
                throw SshError.AuthFailed(SshError.AUTH_REJECTED)
            } catch (e: IOException) {
                runCatching { ssh.disconnect() }
                _state.value = SshState.Disconnected(null)
                throw SshError.HandshakeFailed()
            }

            client = ssh
            _state.value = SshState.Connected
        }
    }

    override suspend fun openShell(termType: String, cols: Int, rows: Int) {
        withContext(io) {
            val ssh = client ?: throw SshError.ChannelFailed()
            try {
                val s = ssh.startSession()
                s.allocatePTY(termType, cols, rows, 0, 0, emptyMap())
                val sh = s.startShell()
                session = s
                shell = sh
                stdin = sh.outputStream
                readJob = scope.launch { pump(sh.inputStream) }
            } catch (e: IOException) {
                throw SshError.ChannelFailed()
            }
        }
    }

    private suspend fun pump(input: InputStream) {
        val buf = ByteArray(READ_BUFFER)
        try {
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                _output.emit(buf.copyOf(n))
            }
            _state.value = SshState.Disconnected(null)
        } catch (e: IOException) {
            _state.value = SshState.Disconnected(SshError.Disconnected().message)
        }
    }

    override suspend fun write(data: ByteArray) {
        withContext(io) {
            val out = stdin ?: return@withContext
            runCatching {
                out.write(data)
                out.flush()
            }
            Unit
        }
    }

    override suspend fun resize(cols: Int, rows: Int) {
        withContext(io) {
            runCatching { shell?.changeWindowDimensions(cols, rows, 0, 0) }
            Unit
        }
    }

    override fun disconnect() {
        readJob?.cancel()
        runCatching { session?.close() }
        runCatching { client?.disconnect() }
        shell = null
        stdin = null
        session = null
        client = null
        _state.value = SshState.Disconnected(null)
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
        const val READ_BUFFER = 8192

        /**
         * Android registers a stripped-down BouncyCastle as "BC"; sshj needs the
         * full provider. Swap it once, idempotently.
         */
        @Synchronized
        fun installBouncyCastle() {
            if (Security.getProvider("BC") is BouncyCastleProvider) return
            Security.removeProvider("BC")
            Security.addProvider(BouncyCastleProvider())
        }
    }
}
