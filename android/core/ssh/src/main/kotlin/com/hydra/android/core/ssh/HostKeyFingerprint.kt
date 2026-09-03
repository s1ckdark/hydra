package com.hydra.android.core.ssh

/** A host's public key as presented during the handshake. */
data class HostKeyFingerprint(
    val keyType: String,
    val publicKeyBase64: String,
    /** Display form, e.g. "SHA256:0Y3v…". Shown in the trust prompt. */
    val sha256: String,
)
