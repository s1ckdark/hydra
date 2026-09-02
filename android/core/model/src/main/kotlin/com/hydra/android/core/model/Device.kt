package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

/** Mirrors internal/domain/device.go and Hydra/Hydra/Models/Device.swift. */
@Serializable
data class Device(
    val id: String,
    val name: String = "",
    val hostname: String = "",
    val ipAddresses: List<String> = emptyList(),
    val tailscaleIp: String = "",
    val os: String = "",
    val status: String,
    val isExternal: Boolean = false,
    val tags: List<String>? = null,
    val user: String = "",
    @Serializable(with = InstantSerializer::class) val lastSeen: Instant,
    val sshEnabled: Boolean = false,
    val hasGpu: Boolean = false,
    val gpuModel: String? = null,
    val gpuCount: Int = 0,
) {
    /** Trust the server's reported status; it already applies its own staleness filter. */
    val isOnline: Boolean get() = status == "online"

    val displayName: String get() = name.ifEmpty { hostname }

    /** Hostname up to the first dot — the short label used on cards. */
    val shortName: String get() = hostname.substringBefore('.').ifEmpty { displayName }
}
