package com.hydra.android.core.ssh

/**
 * A transport failure already translated into something the UI can show.
 * Mirrors the ApiException convention from :core:network.
 */
sealed class SshError(message: String) : Exception(message) {
    class Unreachable : SshError("서버에 연결할 수 없습니다")
    class HandshakeFailed : SshError("SSH 핸드셰이크에 실패했습니다")
    class AuthFailed(message: String) : SshError(message)
    class ChannelFailed : SshError("셸을 열지 못했습니다")
    class HostKeyMismatch : SshError("호스트 키가 저장된 값과 다릅니다 — 연결을 차단했습니다")
    class Disconnected : SshError("연결이 종료되었습니다")

    companion object {
        const val AUTH_REJECTED = "인증에 실패했습니다 (키를 서버에 등록했는지 확인하세요)"
        const val NO_KEY = "SSH 키가 저장되어 있지 않습니다"
    }
}
