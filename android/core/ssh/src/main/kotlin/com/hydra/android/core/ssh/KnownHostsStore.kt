package com.hydra.android.core.ssh

import java.io.File

data class KnownHostsEntry(
    val host: String,
    val keyType: String,
    val publicKeyBase64: String,
)

enum class KnownHostsCheck { UNKNOWN, MATCH, MISMATCH }

/**
 * TOFU store in known_hosts format minus hashing: one `host keyType base64`
 * line per entry.
 *
 * iOS's store also decodes hashed `|1|salt|hash` entries, because macOS
 * OpenSSH writes them and the app has to recognise hosts the user's ssh CLI
 * already trusts. Android has no system known_hosts to interoperate with, so
 * that path would be dead weight and is deliberately absent.
 */
class KnownHostsStore(private val file: File) {

    fun readAll(): List<KnownHostsEntry> {
        if (!file.exists()) return emptyList()
        return file.readLines().mapNotNull { line ->
            val trimmed = line.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("#")) return@mapNotNull null
            val parts = trimmed.split(Regex("\\s+"))
            if (parts.size < 3) null else KnownHostsEntry(parts[0], parts[1], parts[2])
        }
    }

    /**
     * Matched on (host, keyType) together. A host legitimately serves several
     * key types, so looking at host alone would report MISMATCH for a host that
     * is merely offering a different type — a false alarm indistinguishable
     * from a real machine-in-the-middle.
     */
    fun check(entry: KnownHostsEntry): KnownHostsCheck {
        val candidates = readAll().filter {
            it.host == entry.host && it.keyType == entry.keyType
        }
        if (candidates.isEmpty()) return KnownHostsCheck.UNKNOWN
        return if (candidates.any { it.publicKeyBase64 == entry.publicKeyBase64 }) {
            KnownHostsCheck.MATCH
        } else {
            KnownHostsCheck.MISMATCH
        }
    }

    fun add(entry: KnownHostsEntry) {
        file.parentFile?.mkdirs()
        val line = "${entry.host} ${entry.keyType} ${entry.publicKeyBase64}"
        val existing = if (file.exists()) file.readText() else ""
        val prefix = if (existing.isEmpty() || existing.endsWith("\n")) "" else "\n"
        file.appendText("$prefix$line\n")
    }
}
