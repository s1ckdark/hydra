# Android 디바이스 탭 + SSH 터미널 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 디바이스 tab to the Android client and a working full-screen SSH terminal behind it, with key import and TOFU host-key trust.

**Architecture:** Two new modules join the v1 graph. `:core:ssh` wraps sshj behind an `SshTransport` interface mirroring iOS's `SSHSession`, with TOFU enforced inside sshj's `HostKeyVerifier`. `:core:terminal` vendors Termux's Apache-2.0 terminal emulator and view, and supplies the one class we own — a `com.termux.terminal.TerminalSession` backed by SSH instead of a local pty — so the 1,500-line `TerminalView` is vendored unmodified.

**Tech Stack:** Kotlin 2.1, Jetpack Compose, Hilt, `com.hierynomus:sshj:0.40.0`, BouncyCastle 1.80, `uk.uuid.slf4j:slf4j-android:2.0.17-0`, vendored Termux Java.

**Spec:** `docs/superpowers/specs/2026-09-03-android-terminal-design.md`

## Global Constraints

- All work lives under `android/`. Do not touch Go (`cmd/`, `internal/`) or Swift (`Hydra/`) sources.
- Package root `com.hydra.android`, except the vendored tree and our replacement session, which are `com.termux.*` by necessity.
- compileSdk 36, targetSdk 36, minSdk 26. No NDK — the vendored set deliberately excludes everything needing `libtermux.so`.
- `JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS` on every Gradle invocation; `java` is not on PATH. `make android-build` / `make android-test` already set it.
- Both Java and Kotlin emit **17** bytecode; the toolchain runs on 21. Do not raise either — a mismatch fails KSP with "Inconsistent JVM-target compatibility".
- Vendored upstream is `termux/termux-app` at commit **3b66f8799635a4dba4a206563048ff0e6792c487**. Record it in `VENDORED.md` and never edit a vendored file.
- Korean UI strings, matching the existing app. No localization.
- Every task ends with a commit. Work on branch `feat/android-terminal`.

### Verified library facts — build on these, do not re-derive

- `net.schmizz.sshj.AndroidConfig` exists in 0.40.0 and is the config to use on Android.
- `HostKeyVerifier` is `boolean verify(String hostname, int port, PublicKey key)` plus `List<String> findExistingAlgorithms(String, int)`.
- `SSHClient.loadKeys(String privateKey, String publicKey, PasswordFinder)` detects the format **from content** (`KeyProviderUtil.detectKeyFileFormat`) and never touches disk. Pass the PEM directly; do not write a temp file.
- `Session.Shell.changeWindowDimensions(int cols, int rows, int width, int height)` is the resize call.
- Key serialization for known_hosts: `KeyType.fromKey(key).toString()` gives `ssh-ed25519` etc.; `PlainBuffer().putPublicKey(key).compactData` gives the SSH wire bytes to Base64 and to SHA-256 for the fingerprint.
- `TerminalEmulator`'s constructor is `TerminalEmulator(TerminalOutput session, int columns, int rows, int cellWidthPixels, int cellHeightPixels, Integer transcriptRows, TerminalSessionClient client)`.
- `TerminalView` calls exactly four members on the session: `write`, `writeCodePoint`, `getEmulator`, `updateSize`. `getEmulator()` returning null before the first sizing is expected — `TerminalView` guards `mEmulator == null` in 15 places.

---

## File Structure

```
android/
├── core/ssh/                                  NEW
│   └── src/main/kotlin/com/hydra/android/core/ssh/
│       ├── SshTransport.kt                    interface + SshState + SshAuth
│       ├── SshError.kt                        sealed error type + Korean messages
│       ├── HostKeyFingerprint.kt              keyType / publicKeyBase64 / sha256
│       ├── KnownHostsStore.kt                 file-backed TOFU store
│       ├── HostKeyGate.kt                     match/unknown/mismatch → decision
│       ├── SshCredentials.kt                  resolver over SecureStore + settings
│       ├── SshjTransport.kt                   the only SshTransport implementation
│       └── SshModule.kt                       Hilt bindings
├── core/terminal/                             NEW
│   ├── VENDORED.md                            provenance + what we replaced
│   └── src/main/
│       ├── java/com/termux/**                 vendored, never edited
│       └── kotlin/
│           ├── com/termux/terminal/TerminalSession.kt        OURS — the replacement
│           └── com/hydra/android/core/terminal/
│               └── HydraSessionClient.kt      TerminalSessionClient impl
├── feature/devices/                           NEW  list + ViewModel + nav
├── feature/terminal/                          NEW  screen + ViewModel + view client
├── core/data/…/SecureStore.kt                 MODIFY  add SSH key accessors
├── core/data/…/SettingsRepository.kt          MODIFY  add sshUsername
├── feature/settings/…                         MODIFY  SSH section + key screen
└── app/…/HydraApp.kt                          MODIFY  4 tabs + terminal route
```

---

### Task 1: `:core:ssh` — known-hosts store and the TOFU gate

Pure JVM logic, no Android dependencies, so it is the cheapest place to pin down the trust rules.

**Files:**
- Create: `android/core/ssh/build.gradle.kts`
- Create: `.../core/ssh/HostKeyFingerprint.kt`, `KnownHostsStore.kt`, `HostKeyGate.kt`
- Test: `android/core/ssh/src/test/kotlin/com/hydra/android/core/ssh/KnownHostsStoreTest.kt`, `HostKeyGateTest.kt`
- Modify: `android/settings.gradle.kts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `data class HostKeyFingerprint(val keyType: String, val publicKeyBase64: String, val sha256: String)`
  - `data class KnownHostsEntry(val host: String, val keyType: String, val publicKeyBase64: String)`
  - `enum class KnownHostsCheck { UNKNOWN, MATCH, MISMATCH }`
  - `class KnownHostsStore(file: File)` with `check(entry): KnownHostsCheck`, `add(entry)`, `readAll(): List<KnownHostsEntry>`
  - `sealed interface HostKeyDecision { data object Proceed; data class NeedsTrust(val sha256: String); data object Blocked }`
  - `object HostKeyGate { fun evaluate(host: String, fingerprint: HostKeyFingerprint?, store: KnownHostsStore): HostKeyDecision }`

- [ ] **Step 1: Register the module and write its build file**

Add to `android/settings.gradle.kts`, inside the existing `include(":core:model", …)` line's group:

```kotlin
include(":core:model", ":core:network", ":core:data", ":core:designsystem", ":core:ssh", ":core:terminal")
include(":feature:dashboard", ":feature:chat", ":feature:settings", ":feature:devices", ":feature:terminal")
```

`android/core/ssh/build.gradle.kts`:

```kotlin
plugins {
    id("hydra.android.library")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android { namespace = "com.hydra.android.core.ssh" }

dependencies {
    api(project(":core:model"))
    implementation(project(":core:data"))
    implementation(libs.sshj)
    implementation(libs.slf4j.android)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
```

Add to `android/gradle/libs.versions.toml` under `[versions]`: `sshj = "0.40.0"`, `slf4jAndroid = "2.0.17-0"`. Under `[libraries]`:

```toml
sshj = { module = "com.hierynomus:sshj", version.ref = "sshj" }
slf4j-android = { module = "uk.uuid.slf4j:slf4j-android", version.ref = "slf4jAndroid" }
```

Create `android/core/terminal/build.gradle.kts` as a placeholder so configuration succeeds — Task 4 fills it in:

```kotlin
plugins { id("hydra.android.library") }
android { namespace = "com.hydra.android.core.terminal" }
```

Do the same for `android/feature/devices/build.gradle.kts` and `android/feature/terminal/build.gradle.kts` with namespaces `com.hydra.android.feature.devices` and `com.hydra.android.feature.terminal`.

- [ ] **Step 2: Write the failing known-hosts tests**

`KnownHostsStoreTest.kt`:

```kotlin
package com.hydra.android.core.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class KnownHostsStoreTest {

    @get:Rule val temp = TemporaryFolder()

    private fun store(vararg lines: String): KnownHostsStore {
        val f = File(temp.root, "known_hosts")
        f.writeText(lines.joinToString("\n"))
        return KnownHostsStore(f)
    }

    private fun entry(host: String, type: String = "ssh-ed25519", key: String = "AAAAKEY") =
        KnownHostsEntry(host, type, key)

    @Test
    fun `an unseen host reads as unknown`() {
        assertEquals(KnownHostsCheck.UNKNOWN, store().check(entry("10.0.0.1")))
    }

    @Test
    fun `a stored host with the same key reads as match`() {
        val s = store("10.0.0.1 ssh-ed25519 AAAAKEY")
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `a stored host with a different key of the same type reads as mismatch`() {
        val s = store("10.0.0.1 ssh-ed25519 OTHERKEY")
        assertEquals(KnownHostsCheck.MISMATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `a different key type for a known host reads as unknown, never mismatch`() {
        // A host legitimately serves several key types. Matching on host alone
        // would report a mismatch for a host merely offering a different type,
        // which is a false machine-in-the-middle alarm. (iOS patch I3.)
        val s = store("10.0.0.1 ssh-rsa RSAKEY")
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(entry("10.0.0.1", "ssh-ed25519", "EDKEY")))
    }

    @Test
    fun `another host's entry does not satisfy this host`() {
        val s = store("10.0.0.2 ssh-ed25519 AAAAKEY")
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `blank lines and comments are ignored`() {
        val s = store("", "# a comment", "10.0.0.1 ssh-ed25519 AAAAKEY", "")
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `malformed lines are skipped rather than throwing`() {
        val s = store("garbage", "10.0.0.1 ssh-ed25519 AAAAKEY")
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `a missing file reads as unknown rather than throwing`() {
        val s = KnownHostsStore(File(temp.root, "does-not-exist"))
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(entry("10.0.0.1")))
    }

    @Test
    fun `add persists an entry that then matches`() {
        val f = File(temp.root, "known_hosts")
        val s = KnownHostsStore(f)
        s.add(entry("10.0.0.1"))
        assertEquals(KnownHostsCheck.MATCH, s.check(entry("10.0.0.1")))
        assertTrue(f.readText().contains("10.0.0.1 ssh-ed25519 AAAAKEY"))
    }

    @Test
    fun `add keeps existing entries`() {
        val f = File(temp.root, "known_hosts")
        f.writeText("10.0.0.2 ssh-rsa RSAKEY\n")
        val s = KnownHostsStore(f)
        s.add(entry("10.0.0.1"))
        assertEquals(2, s.readAll().size)
    }
}
```

`HostKeyGateTest.kt`:

```kotlin
package com.hydra.android.core.ssh

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class HostKeyGateTest {

    @get:Rule val temp = TemporaryFolder()

    private fun store(vararg lines: String) =
        KnownHostsStore(File(temp.root, "kh").apply { writeText(lines.joinToString("\n")) })

    private val fp = HostKeyFingerprint("ssh-ed25519", "AAAAKEY", "SHA256:abc")

    @Test
    fun `a known matching key proceeds`() {
        val d = HostKeyGate.evaluate("10.0.0.1", fp, store("10.0.0.1 ssh-ed25519 AAAAKEY"))
        assertEquals(HostKeyDecision.Proceed, d)
    }

    @Test
    fun `an unknown host needs trust and carries the fingerprint`() {
        val d = HostKeyGate.evaluate("10.0.0.1", fp, store())
        assertEquals(HostKeyDecision.NeedsTrust("SHA256:abc"), d)
    }

    @Test
    fun `a changed key is blocked without prompting`() {
        val d = HostKeyGate.evaluate("10.0.0.1", fp, store("10.0.0.1 ssh-ed25519 DIFFERENT"))
        assertEquals(HostKeyDecision.Blocked, d)
    }

    @Test
    fun `a missing fingerprint is blocked`() {
        val d = HostKeyGate.evaluate("10.0.0.1", null, store())
        assertEquals(HostKeyDecision.Blocked, d)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:ssh:testDebugUnitTest
```

Expected: FAIL — unresolved references `KnownHostsStore`, `HostKeyGate`, `HostKeyFingerprint`.

- [ ] **Step 4: Write the implementation**

`HostKeyFingerprint.kt`:

```kotlin
package com.hydra.android.core.ssh

/** A host's public key as presented during the handshake. */
data class HostKeyFingerprint(
    val keyType: String,
    val publicKeyBase64: String,
    /** Display form, e.g. "SHA256:0Y3v…". Shown in the trust prompt. */
    val sha256: String,
)
```

`KnownHostsStore.kt`:

```kotlin
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
            if (parts.size < 3) null
            else KnownHostsEntry(parts[0], parts[1], parts[2])
        }
    }

    /**
     * Matched on (host, keyType) together. A host legitimately serves several
     * key types, so looking at host alone would report MISMATCH for a host
     * that is merely offering a different type — a false alarm indistinguishable
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
```

`HostKeyGate.kt`:

```kotlin
package com.hydra.android.core.ssh

sealed interface HostKeyDecision {
    data object Proceed : HostKeyDecision
    data class NeedsTrust(val sha256: String) : HostKeyDecision
    data object Blocked : HostKeyDecision
}

/**
 * Trust-on-first-use gate. A MISMATCH is blocked outright rather than offered
 * as a "trust anyway" button: a changed host key is the exact signature of a
 * machine-in-the-middle, and a dialog trains the user to click through it.
 */
object HostKeyGate {
    fun evaluate(
        host: String,
        fingerprint: HostKeyFingerprint?,
        store: KnownHostsStore,
    ): HostKeyDecision {
        if (fingerprint == null) return HostKeyDecision.Blocked
        val entry = KnownHostsEntry(host, fingerprint.keyType, fingerprint.publicKeyBase64)
        return when (store.check(entry)) {
            KnownHostsCheck.MATCH -> HostKeyDecision.Proceed
            KnownHostsCheck.UNKNOWN -> HostKeyDecision.NeedsTrust(fingerprint.sha256)
            KnownHostsCheck.MISMATCH -> HostKeyDecision.Blocked
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:ssh:testDebugUnitTest
```

Expected: PASS, 14 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/settings.gradle.kts android/gradle/libs.versions.toml android/core/ssh \
        android/core/terminal android/feature/devices android/feature/terminal
git commit -m "feat(android): known_hosts TOFU 저장소 + 호스트 키 게이트"
```

---

### Task 2: `:core:ssh` — transport contract and credential resolution

**Files:**
- Create: `.../core/ssh/SshTransport.kt`, `SshError.kt`, `SshCredentials.kt`
- Modify: `android/core/data/src/main/kotlin/com/hydra/android/core/data/SecureStore.kt`
- Modify: `android/core/data/src/main/kotlin/com/hydra/android/core/data/SettingsRepository.kt`
- Test: `android/core/ssh/src/test/kotlin/com/hydra/android/core/ssh/SshCredentialResolverTest.kt`

**Interfaces:**
- Consumes: `SecureStore`, `SettingsSource` from `:core:data`.
- Produces:
  - `sealed interface SshState { Idle; Connecting; Connected; data class Disconnected(val reason: String?) }`
  - `sealed class SshError(message: String) : Exception(message)` with `Unreachable`, `HandshakeFailed`, `AuthFailed`, `ChannelFailed`, `HostKeyMismatch`, `Disconnected`
  - `sealed interface SshAuth { data class PrivateKey(val pem: String) : SshAuth }`
  - `interface SshTransport` (see Step 3)
  - `data class SshCredentials(val user: String, val port: Int, val privateKeyPem: String)`
  - `class SshCredentialResolver(secureStore, settings) { suspend fun resolve(): SshCredentials }`
  - `SecureStore.getSshPrivateKey(): String?` / `setSshPrivateKey(value: String)`
  - `SettingsSource.sshUsername: Flow<String>` / `setSshUsername(value: String)`

- [ ] **Step 1: Write the failing credential tests**

```kotlin
package com.hydra.android.core.ssh

import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeSecureStore(var apiKey: String? = null, var sshKey: String? = null) : SecureStore {
    override fun getApiKey() = apiKey
    override fun setApiKey(value: String) { apiKey = value.ifEmpty { null } }
    override fun getSshPrivateKey() = sshKey
    override fun setSshPrivateKey(value: String) { sshKey = value.ifEmpty { null } }
}

private class FakeSettings(username: String = "root") : SettingsSource {
    override val serverUrl = MutableStateFlow("http://localhost:8080")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(false)
    override val sshUsername = MutableStateFlow(username)
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
    override suspend fun setSshUsername(value: String) { sshUsername.value = value }
}

class SshCredentialResolverTest {

    @Test
    fun `resolves the stored key, username and default port`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(sshKey = "PEMBODY"), FakeSettings("dave"))
        val creds = r.resolve()
        assertEquals("dave", creds.user)
        assertEquals(22, creds.port)
        assertEquals("PEMBODY", creds.privateKeyPem)
    }

    @Test
    fun `a missing key fails before dialing, with an actionable message`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(sshKey = null), FakeSettings())
        val e = runCatching { r.resolve() }.exceptionOrNull()
        assertTrue(e is SshError.AuthFailed)
        assertEquals("SSH 키가 저장되어 있지 않습니다", e!!.message)
    }

    @Test
    fun `a blank stored key counts as missing`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(sshKey = "   "), FakeSettings())
        assertTrue(runCatching { r.resolve() }.exceptionOrNull() is SshError.AuthFailed)
    }

    @Test
    fun `a blank username falls back to root`() = runTest {
        val r = SshCredentialResolver(FakeSecureStore(sshKey = "PEM"), FakeSettings(""))
        assertEquals("root", r.resolve().user)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:ssh:testDebugUnitTest
```

Expected: FAIL — `SecureStore` has no `getSshPrivateKey`, `SettingsSource` has no `sshUsername`, `SshCredentialResolver` undefined.

- [ ] **Step 3: Write the transport contract**

`SshError.kt`:

```kotlin
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
```

`SshTransport.kt`:

```kotlin
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
```

`SshCredentials.kt`:

```kotlin
package com.hydra.android.core.ssh

import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import kotlinx.coroutines.flow.first
import javax.inject.Inject

data class SshCredentials(val user: String, val port: Int, val privateKeyPem: String)

/**
 * Same shape as iOS `TerminalSession.defaultCredentials`: one imported key,
 * the sshUsername setting, port 22. A missing key is reported before dialing
 * so the user gets "no key stored" rather than an opaque handshake failure.
 */
class SshCredentialResolver @Inject constructor(
    private val secureStore: SecureStore,
    private val settings: SettingsSource,
) {
    suspend fun resolve(): SshCredentials {
        val pem = secureStore.getSshPrivateKey()?.trim().orEmpty()
        if (pem.isEmpty()) throw SshError.AuthFailed(SshError.NO_KEY)
        val user = settings.sshUsername.first().trim().ifEmpty { DEFAULT_USER }
        return SshCredentials(user = user, port = DEFAULT_PORT, privateKeyPem = pem)
    }

    private companion object {
        const val DEFAULT_USER = "root"
        const val DEFAULT_PORT = 22
    }
}
```

- [ ] **Step 4: Extend `SecureStore` and `SettingsSource`**

In `android/core/data/.../SecureStore.kt`, add to the interface:

```kotlin
interface SecureStore {
    fun getApiKey(): String?
    fun setApiKey(value: String)
    fun getSshPrivateKey(): String?
    fun setSshPrivateKey(value: String)
}
```

In `KeystoreSecureStore`, generalize the existing single-key logic. Replace the two public methods and add a private pair, keeping the same AES/GCM envelope:

```kotlin
    override fun getApiKey(): String? = decrypt(KEY_API)
    override fun setApiKey(value: String) = encrypt(KEY_API, value)
    override fun getSshPrivateKey(): String? = decrypt(KEY_SSH)
    override fun setSshPrivateKey(value: String) = encrypt(KEY_SSH, value)

    private fun decrypt(prefKey: String): String? {
        val stored = prefs.getString(prefKey, null) ?: return null
        val parts = stored.split(':')
        if (parts.size != 2) return null
        return runCatching {
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val cipherText = Base64.decode(parts[1], Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        }.getOrNull()
    }

    private fun encrypt(prefKey: String, value: String) {
        if (value.isEmpty()) {
            prefs.edit().remove(prefKey).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encoded = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipherText, Base64.NO_WRAP)
        prefs.edit().putString(prefKey, encoded).apply()
    }
```

Add `const val KEY_SSH = "ssh_private_key_pem"` to its companion, alongside the existing `KEY_API`.

In `SettingsRepository.kt`, add to `SettingsSource`:

```kotlin
    val sshUsername: Flow<String>
    suspend fun setSshUsername(value: String)
```

and to `SettingsRepository`:

```kotlin
    override val sshUsername: Flow<String> =
        context.dataStore.data.map { it[SSH_USERNAME] ?: DEFAULT_SSH_USERNAME }

    override suspend fun setSshUsername(value: String) {
        context.dataStore.edit { it[SSH_USERNAME] = value }
    }
```

with `const val DEFAULT_SSH_USERNAME = "root"` and `private val SSH_USERNAME = stringPreferencesKey("sshUsername")` in its companion.

This reverses v1's deliberate omission of `sshUsername`. v1's spec removed it because "a settings row that controls nothing invites bug reports" — that reasoning expires here, and reversing it is the intended path, not a regression.

- [ ] **Step 5: Update the existing fakes that now fail to compile**

Three v1 test files implement `SecureStore` or `SettingsSource` and must gain the new members:

- `android/feature/settings/src/test/kotlin/.../SettingsViewModelTest.kt` — `FakeSecureStore` and `FakeSettings`
- `android/feature/dashboard/src/test/kotlin/.../DashboardViewModelTest.kt` — `FakeSettings`
- `android/feature/chat/src/test/kotlin/.../ChatViewModelTest.kt` — the inline `SettingsSource` object

Add to each `SecureStore` fake:

```kotlin
    var sshKey: String? = null
    override fun getSshPrivateKey() = sshKey
    override fun setSshPrivateKey(value: String) { sshKey = value.ifEmpty { null } }
```

Add to each `SettingsSource` fake:

```kotlin
    override val sshUsername = MutableStateFlow("root")
    override suspend fun setSshUsername(value: String) { sshUsername.value = value }
```

- [ ] **Step 6: Run the whole suite**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew testDebugUnitTest
```

Expected: PASS — the 91 v1 tests plus 14 from Task 1 plus 4 here = 109.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/ssh android/core/data android/feature
git commit -m "feat(android): SSH transport 계약 + 자격 해석 (sshUsername 복귀)"
```

---

### Task 3: `:core:ssh` — the sshj transport

The one place that talks to sshj. Unit tests cover the pure parts (provider setup idempotence, fingerprint derivation, error translation); the socket path is verified by hand in Task 8.

**Files:**
- Create: `.../core/ssh/SshjTransport.kt`, `TofuHostKeyVerifier.kt`, `SshModule.kt`
- Test: `android/core/ssh/src/test/kotlin/com/hydra/android/core/ssh/TofuHostKeyVerifierTest.kt`

**Interfaces:**
- Consumes: `SshTransport`, `SshState`, `SshAuth`, `SshError`, `HostKeyGate`, `KnownHostsStore`, `HostKeyFingerprint` (Tasks 1-2).
- Produces:
  - `class TofuHostKeyVerifier(store, onNeedsTrust: suspend (HostKeyFingerprint) -> Boolean) : HostKeyVerifier`
  - `fun fingerprintOf(key: PublicKey): HostKeyFingerprint`
  - `class SshjTransport(...) : SshTransport`
  - Hilt `SshModule` providing `KnownHostsStore` (file `context.filesDir/known_hosts`) and `SshCredentialResolver`

- [ ] **Step 1: Write the failing verifier test**

The verifier's decision logic is testable without a socket by feeding it a fingerprint directly.

```kotlin
package com.hydra.android.core.ssh

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TofuHostKeyVerifierTest {

    @get:Rule val temp = TemporaryFolder()

    private fun store(vararg lines: String) =
        KnownHostsStore(File(temp.root, "kh").apply { writeText(lines.joinToString("\n")) })

    private val fp = HostKeyFingerprint("ssh-ed25519", "AAAAKEY", "SHA256:abc")

    @Test
    fun `a known key verifies without prompting`() = runBlocking {
        var prompted = false
        val v = TofuHostKeyVerifier(store("h1 ssh-ed25519 AAAAKEY")) { prompted = true; true }
        assertTrue(v.decide("h1", fp))
        assertFalse(prompted)
    }

    @Test
    fun `an unknown key prompts and stores on acceptance`() = runBlocking {
        val s = store()
        val v = TofuHostKeyVerifier(s) { true }
        assertTrue(v.decide("h1", fp))
        assertEquals(KnownHostsCheck.MATCH, s.check(KnownHostsEntry("h1", "ssh-ed25519", "AAAAKEY")))
    }

    @Test
    fun `an unknown key rejected by the user does not verify and is not stored`() = runBlocking {
        val s = store()
        val v = TofuHostKeyVerifier(s) { false }
        assertFalse(v.decide("h1", fp))
        assertEquals(KnownHostsCheck.UNKNOWN, s.check(KnownHostsEntry("h1", "ssh-ed25519", "AAAAKEY")))
    }

    @Test
    fun `a mismatched key is rejected without prompting`() = runBlocking {
        var prompted = false
        val v = TofuHostKeyVerifier(store("h1 ssh-ed25519 OTHER")) { prompted = true; true }
        assertFalse(v.decide("h1", fp))
        assertFalse(prompted)
    }

    @Test
    fun `the last decision is recorded so the transport can explain a rejection`() = runBlocking {
        val v = TofuHostKeyVerifier(store("h1 ssh-ed25519 OTHER")) { true }
        v.decide("h1", fp)
        assertEquals(HostKeyDecision.Blocked, v.lastDecision)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:ssh:testDebugUnitTest --tests '*TofuHostKeyVerifierTest*'
```

Expected: FAIL — unresolved reference `TofuHostKeyVerifier`.

- [ ] **Step 3: Write the verifier**

```kotlin
package com.hydra.android.core.ssh

import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import java.security.MessageDigest
import java.security.PublicKey
import android.util.Base64

/** OpenSSH-style identity of a presented host key. */
fun fingerprintOf(key: PublicKey): HostKeyFingerprint {
    val wire = Buffer.PlainBuffer().putPublicKey(key).compactData
    val sha = MessageDigest.getInstance("SHA-256").digest(wire)
    return HostKeyFingerprint(
        keyType = KeyType.fromKey(key).toString(),
        publicKeyBase64 = Base64.encodeToString(wire, Base64.NO_WRAP),
        sha256 = "SHA256:" + Base64.encodeToString(sha, Base64.NO_WRAP or Base64.NO_PADDING),
    )
}

/**
 * TOFU inside the handshake. sshj calls `verify` synchronously on the
 * transport's own IO thread, so blocking it on the user's answer is safe —
 * it is never the main thread.
 *
 * This sits earlier than iOS's equivalent: iOS checks trust between connect()
 * and openShell() because libssh2 does not enforce host keys itself. Here an
 * untrusted key never reaches an authenticated session at all.
 */
class TofuHostKeyVerifier(
    private val store: KnownHostsStore,
    private val onNeedsTrust: suspend (HostKeyFingerprint) -> Boolean,
) : HostKeyVerifier {

    /** Set on every decision so the transport can explain a rejection. */
    @Volatile
    var lastDecision: HostKeyDecision = HostKeyDecision.Blocked
        private set

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean =
        runBlocking { decide(hostname, fingerprintOf(key)) }

    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> =
        store.readAll().filter { it.host == hostname }.map { it.keyType }

    /** Extracted from [verify] so the decision is testable without a socket. */
    suspend fun decide(host: String, fingerprint: HostKeyFingerprint): Boolean {
        val decision = HostKeyGate.evaluate(host, fingerprint, store)
        lastDecision = decision
        return when (decision) {
            is HostKeyDecision.Proceed -> true
            is HostKeyDecision.Blocked -> false
            is HostKeyDecision.NeedsTrust -> {
                val accepted = onNeedsTrust(fingerprint)
                if (accepted) {
                    store.add(
                        KnownHostsEntry(host, fingerprint.keyType, fingerprint.publicKeyBase64)
                    )
                }
                accepted
            }
        }
    }
}
```

Note: `android.util.Base64` is not available in plain JVM unit tests. The verifier tests above never call `fingerprintOf`, so they pass — but do not add a test that does without moving to Robolectric.

- [ ] **Step 4: Write the transport**

```kotlin
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
 * The only SshTransport implementation. sshj is blocking, so everything runs
 * on a dedicated single-thread dispatcher — which is also the thread the
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
        replay = 0, extraBufferCapacity = 256, onBufferOverflow = BufferOverflow.SUSPEND,
    )
    override val output: Flow<ByteArray> = _output.asSharedFlow()

    private var client: SSHClient? = null
    private var session: Session? = null
    private var shell: Session.Shell? = null
    private var stdin: OutputStream? = null
    private var readJob: Job? = null
    private var verifier: TofuHostKeyVerifier? = null

    override suspend fun connect(host: String, port: Int, user: String, auth: SshAuth) =
        withContext(io) {
            installBouncyCastle()
            _state.value = SshState.Connecting
            val ssh = SSHClient(AndroidConfig())
            val v = verifierFactory(onNeedsTrust).also { verifier = it }
            ssh.addHostKeyVerifier(v)
            ssh.connectTimeout = CONNECT_TIMEOUT_MS
            try {
                ssh.connect(host, port)
            } catch (e: IOException) {
                // A rejected host key surfaces here as a transport exception;
                // distinguish it so the user sees why rather than "unreachable".
                _state.value = SshState.Disconnected(null)
                throw when (v.lastDecision) {
                    is HostKeyDecision.Blocked -> SshError.HostKeyMismatch()
                    else -> SshError.Unreachable()
                }
            }
            try {
                val pem = (auth as SshAuth.PrivateKey).pem
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

    override suspend fun openShell(termType: String, cols: Int, rows: Int) = withContext(io) {
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

    private suspend fun pump(input: InputStream) {
        val buf = ByteArray(8192)
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

    override suspend fun write(data: ByteArray) = withContext(io) {
        val out = stdin ?: return@withContext
        runCatching { out.write(data); out.flush() }
        Unit
    }

    override suspend fun resize(cols: Int, rows: Int) = withContext(io) {
        runCatching { shell?.changeWindowDimensions(cols, rows, 0, 0) }
        Unit
    }

    override fun disconnect() {
        readJob?.cancel()
        runCatching { session?.close() }
        runCatching { client?.disconnect() }
        shell = null; stdin = null; session = null; client = null
        _state.value = SshState.Disconnected(null)
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000

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
```

`SshModule.kt`:

```kotlin
package com.hydra.android.core.ssh

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.io.File
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object SshModule {

    @Provides
    @Singleton
    fun provideKnownHostsStore(@ApplicationContext context: Context): KnownHostsStore =
        KnownHostsStore(File(context.filesDir, "known_hosts"))
}
```

- [ ] **Step 5: Add packaging excludes for BouncyCastle**

BouncyCastle jars ship `META-INF` signature files that break APK packaging. In `android/build-logic/src/main/kotlin/HydraAndroidApplicationPlugin.kt`, inside the `extensions.configure<ApplicationExtension>` block, add:

```kotlin
            packaging {
                resources {
                    excludes += setOf(
                        "META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA",
                        "META-INF/versions/**", "META-INF/INDEX.LIST",
                    )
                }
            }
```

- [ ] **Step 6: Run the tests and build**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:ssh:testDebugUnitTest :core:ssh:assembleDebug
```

Expected: PASS, 5 verifier tests; `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/ssh android/build-logic
git commit -m "feat(android): sshj transport + 핸드셰이크 내 TOFU 검증"
```

---

### Task 4: `:core:terminal` — vendor Termux and supply our session

**Files:**
- Create: `android/core/terminal/VENDORED.md`
- Create: `android/core/terminal/src/main/java/com/termux/**` (downloaded)
- Create: `.../src/main/kotlin/com/termux/terminal/TerminalSession.kt`
- Create: `.../src/main/kotlin/com/hydra/android/core/terminal/HydraSessionClient.kt`
- Modify: `android/core/terminal/build.gradle.kts`
- Test: `android/core/terminal/src/test/kotlin/com/hydra/android/core/terminal/TerminalSessionTest.kt`

**Interfaces:**
- Consumes: `SshTransport`, `SshState` (Task 2).
- Produces: `com.termux.terminal.TerminalSession(transport, scope, clipboard, onTitleChanged)` with `write(ByteArray/String)`, `writeCodePoint(Boolean, Int)`, `getEmulator(): TerminalEmulator?`, `updateSize(Int, Int, Int, Int)`, `suspend fun start(host, port, user, auth)`, `fun close()`, `val sizeKnown: Boolean`.

- [ ] **Step 1: Download the vendored sources**

```bash
cd /Users/dave/iWorks/hydra/android/core/terminal
SHA=3b66f8799635a4dba4a206563048ff0e6792c487
BASE="https://raw.githubusercontent.com/termux/termux-app/$SHA"
mkdir -p src/main/java/com/termux/terminal
mkdir -p src/main/java/com/termux/view/support src/main/java/com/termux/view/textselection

for f in ByteQueue KeyHandler Logger TerminalBuffer TerminalColorScheme TerminalColors \
         TerminalEmulator TerminalOutput TerminalRow TerminalSessionClient TextStyle WcWidth; do
  curl -fsSL -o "src/main/java/com/termux/terminal/$f.java" \
    "$BASE/terminal-emulator/src/main/java/com/termux/terminal/$f.java"
done

for f in TerminalView TerminalRenderer GestureAndScaleRecognizer TerminalViewClient; do
  curl -fsSL -o "src/main/java/com/termux/view/$f.java" \
    "$BASE/terminal-view/src/main/java/com/termux/view/$f.java"
done
curl -fsSL -o src/main/java/com/termux/view/support/PopupWindowCompatGingerbread.java \
  "$BASE/terminal-view/src/main/java/com/termux/view/support/PopupWindowCompatGingerbread.java"
for f in CursorController TextSelectionCursorController TextSelectionHandleView; do
  curl -fsSL -o "src/main/java/com/termux/view/textselection/$f.java" \
    "$BASE/terminal-view/src/main/java/com/termux/view/textselection/$f.java"
done

find src/main/java -name '*.java' | wc -l   # expect 20
```

`JNI.java` and `TerminalSession.java` are deliberately absent — they are the local-pty path and pull in `libtermux.so`.

- [ ] **Step 2: Write `VENDORED.md`**

```markdown
# Vendored: Termux terminal emulator and view

Upstream: https://github.com/termux/termux-app
Commit:   3b66f8799635a4dba4a206563048ff0e6792c487

## License

`termux-app` is GPLv3, but its root `LICENSE.md` carves out an exception:
`terminal-view` and `terminal-emulator` derive from
[Terminal Emulator for Android](https://github.com/jackpal/Android-Terminal-Emulator)
and are **Apache-2.0**. Only those two directories are vendored here.

## What is vendored

`src/main/java/com/termux/**` — 20 files, copied byte-for-byte and never edited.

From `terminal-emulator/.../com/termux/terminal/` (12 of 14):
ByteQueue, KeyHandler, Logger, TerminalBuffer, TerminalColorScheme, TerminalColors,
TerminalEmulator, TerminalOutput, TerminalRow, TerminalSessionClient, TextStyle, WcWidth

From `terminal-view/.../com/termux/view/` (8, including `support/` and `textselection/`).

## What is excluded, and why

- `JNI.java` and `TerminalSession.java` — upstream's `TerminalSession` is `final`
  and creates a **local pty** via `JNI.createSubprocess`, backed by native
  `libtermux.so`. It cannot be subclassed or reused for SSH.
- `terminal-emulator/src/main/jni/` — the C sources behind that JNI. Excluding
  them means this app needs no NDK.

## What we replaced

`src/main/kotlin/com/termux/terminal/TerminalSession.kt` is **ours**. It occupies
the same package and class name so the vendored `TerminalView` links against it
unmodified. `TerminalView` calls only four members on a session — `write`,
`writeCodePoint`, `getEmulator`, `updateSize` — so satisfying those is enough.

Patch surface is exactly one file. To re-vendor: re-download the list above at a
new commit and re-check those four call sites in `TerminalView.java`.
```

- [ ] **Step 3: Write the module build file**

```kotlin
plugins {
    id("hydra.android.library")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android {
    namespace = "com.hydra.android.core.terminal"
    // The vendored Termux Java predates our lint baseline and is not ours to fix.
    lint { disable += setOf("all") }
}

dependencies {
    api(project(":core:ssh"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
```

- [ ] **Step 4: Write the failing session tests**

```kotlin
package com.hydra.android.core.terminal

import com.hydra.android.core.ssh.SshAuth
import com.hydra.android.core.ssh.SshState
import com.hydra.android.core.ssh.SshTransport
import com.termux.terminal.TerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeTransport : SshTransport {
    val outputFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)
    override val output = outputFlow
    override val state = MutableStateFlow<SshState>(SshState.Idle)

    var connected = false
    var shellArgs: Triple<String, Int, Int>? = null
    val writes = mutableListOf<ByteArray>()
    val resizes = mutableListOf<Pair<Int, Int>>()
    var disconnected = false

    override suspend fun connect(host: String, port: Int, user: String, auth: SshAuth) {
        connected = true
        state.value = SshState.Connected
    }
    override suspend fun openShell(termType: String, cols: Int, rows: Int) {
        shellArgs = Triple(termType, cols, rows)
    }
    override suspend fun write(data: ByteArray) { writes += data }
    override suspend fun resize(cols: Int, rows: Int) { resizes += cols to rows }
    override fun disconnect() { disconnected = true }
}

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalSessionTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun session(t: FakeTransport, scope: TestScope) = TerminalSession(
        transport = t,
        scope = scope,
        onTitleChanged = {},
        onBell = {},
        onCopyToClipboard = {},
        onPasteFromClipboard = {},
    )

    @Test
    fun `no emulator exists before the view reports a size`() = runTest {
        val s = session(FakeTransport(), this)
        assertNull(s.emulator)
        assertFalse(s.sizeKnown)
    }

    @Test
    fun `updateSize creates the emulator with those dimensions`() = runTest {
        val s = session(FakeTransport(), this)
        s.updateSize(100, 40, 10, 20)
        assertNotNull(s.emulator)
        assertEquals(100, s.emulator!!.mColumns)
        assertEquals(40, s.emulator!!.mRows)
        assertTrue(s.sizeKnown)
    }

    @Test
    fun `the shell opens only after both the connect and the first sizing`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)

        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        advanceUntilIdle()
        assertNull("shell must wait for a size", t.shellArgs)

        s.updateSize(100, 40, 10, 20)
        advanceUntilIdle()
        assertEquals(Triple("xterm-256color", 100, 40), t.shellArgs)
    }

    @Test
    fun `sizing before connecting still opens the shell once connected`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)

        s.updateSize(90, 30, 10, 20)
        advanceUntilIdle()
        assertNull(t.shellArgs)

        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        advanceUntilIdle()
        assertEquals(Triple("xterm-256color", 90, 30), t.shellArgs)
    }

    @Test
    fun `the shell is opened once, not on every resize`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        s.updateSize(100, 40, 10, 20)
        advanceUntilIdle()
        s.updateSize(120, 50, 10, 20)
        advanceUntilIdle()
        assertEquals(Triple("xterm-256color", 100, 40), t.shellArgs)
        assertEquals(listOf(120 to 50), t.resizes)
    }

    @Test
    fun `output arriving before the emulator exists is buffered and replayed`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.start("h", 22, "u", SshAuth.PrivateKey("PEM"))
        advanceUntilIdle()

        t.outputFlow.emit("hello".toByteArray())
        advanceUntilIdle()

        s.updateSize(80, 24, 10, 20)
        advanceUntilIdle()

        val screen = s.emulator!!.screen.getSelectedText(0, 0, 79, 0)
        assertTrue("expected replayed output, got '$screen'", screen.startsWith("hello"))
    }

    @Test
    fun `write forwards bytes to the transport`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.write("ls\n".toByteArray(), 0, 3)
        advanceUntilIdle()
        assertArrayEquals("ls\n".toByteArray(), t.writes.single())
    }

    @Test
    fun `close disconnects the transport`() = runTest {
        val t = FakeTransport()
        val s = session(t, this)
        s.close()
        assertTrue(t.disconnected)
    }
}
```

- [ ] **Step 5: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:terminal:testDebugUnitTest
```

Expected: FAIL — no `com.termux.terminal.TerminalSession` constructor of that shape.

- [ ] **Step 6: Write `HydraSessionClient`**

```kotlin
package com.hydra.android.core.terminal

import android.util.Log
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * The vendored `TerminalSessionClient` is a 16-method interface, mostly logging.
 * `setTerminalShellPid` is pty-specific and has no meaning over SSH — it is a
 * deliberate no-op, inherited from the vendored contract rather than an oversight.
 */
class HydraSessionClient(
    private val onTitle: (String?) -> Unit,
    private val onBellRung: () -> Unit,
    private val onCopy: (String) -> Unit,
    private val onPaste: () -> Unit,
) : TerminalSessionClient {

    override fun onTextChanged(changedSession: TerminalSession) = Unit
    override fun onTitleChanged(changedSession: TerminalSession) = onTitle(changedSession.title)
    override fun onSessionFinished(finishedSession: TerminalSession) = Unit
    override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {
        text?.let(onCopy)
    }
    override fun onPasteTextFromClipboard(session: TerminalSession?) = onPaste()
    override fun onBell(session: TerminalSession) = onBellRung()
    override fun onColorsChanged(session: TerminalSession) = Unit
    override fun onTerminalCursorStateChange(state: Boolean) = Unit
    override fun setTerminalShellPid(session: TerminalSession, pid: Int) = Unit

    override fun logError(tag: String?, message: String?) { Log.e(tag ?: TAG, message ?: "") }
    override fun logWarn(tag: String?, message: String?) { Log.w(tag ?: TAG, message ?: "") }
    override fun logInfo(tag: String?, message: String?) { Log.i(tag ?: TAG, message ?: "") }
    override fun logDebug(tag: String?, message: String?) { Log.d(tag ?: TAG, message ?: "") }
    override fun logVerbose(tag: String?, message: String?) { Log.v(tag ?: TAG, message ?: "") }
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
        Log.e(tag ?: TAG, message ?: "", e)
    }
    override fun logStackTrace(tag: String?, e: Exception?) { Log.e(tag ?: TAG, "", e) }

    private companion object { const val TAG = "HydraTerminal" }
}
```

If the vendored interface's exact signatures differ (nullability or an added method at this commit), match the file on disk — it is the authority, not this listing.

- [ ] **Step 7: Write our `TerminalSession`**

```kotlin
package com.termux.terminal

import com.hydra.android.core.ssh.SshAuth
import com.hydra.android.core.ssh.SshTransport
import com.hydra.android.core.terminal.HydraSessionClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/**
 * Our replacement for Termux's `TerminalSession`, which is `final` and forks a
 * local pty through JNI. Same package and class name so the vendored
 * `TerminalView` links against it unmodified; it calls only `write`,
 * `writeCodePoint`, `getEmulator` and `updateSize`.
 *
 * Threading: `TerminalEmulator` is not thread-safe. Termux confines it to the
 * main thread via a Handler; we do the same by collecting the SSH output flow
 * on `Dispatchers.Main`, which is also where `TerminalView` reads it.
 */
class TerminalSession(
    private val transport: SshTransport,
    private val scope: CoroutineScope,
    onTitleChanged: (String?) -> Unit,
    onBell: () -> Unit,
    onCopyToClipboard: (String) -> Unit,
    onPasteFromClipboard: () -> Unit,
) : TerminalOutput() {

    var title: String? = null
        private set

    private val client = HydraSessionClient(
        onTitle = onTitleChanged,
        onBellRung = onBell,
        onCopy = onCopyToClipboard,
        onPaste = onPasteFromClipboard,
    )

    /** Null until the view reports a size. `TerminalView` guards on this. */
    var emulator: TerminalEmulator? = null
        private set

    val sizeKnown: Boolean get() = emulator != null

    private var connected = false
    private var shellOpened = false
    /** Bytes that arrived before the emulator existed. */
    private val pending = ArrayList<ByteArray>()

    init {
        transport.output
            .onEach { bytes -> deliver(bytes) }
            .launchIn(scope + Dispatchers.Main)
    }

    /** Starts the SSH connection. The shell waits for [updateSize]. */
    suspend fun start(host: String, port: Int, user: String, auth: SshAuth) {
        transport.connect(host, port, user, auth)
        connected = true
        openShellIfReady()
    }

    /**
     * Called by `TerminalView` on layout. First call creates the emulator and,
     * if the connection is up, opens the shell at the real size.
     *
     * iOS opens the shell at a hardcoded 80x24 before layout and re-applies the
     * true size afterwards, which loses a resize that lands before openShell
     * completes. Waiting for the size removes the window entirely.
     */
    fun updateSize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        val existing = emulator
        if (existing == null) {
            emulator = TerminalEmulator(
                this, columns, rows, cellWidthPixels, cellHeightPixels, TRANSCRIPT_ROWS, client,
            )
            flushPending()
            scope.launch { openShellIfReady() }
        } else {
            existing.resize(columns, rows)
            scope.launch { transport.resize(columns, rows) }
        }
    }

    fun getEmulator(): TerminalEmulator? = emulator

    private suspend fun openShellIfReady() {
        if (shellOpened || !connected) return
        val e = emulator ?: return
        shellOpened = true
        transport.openShell(TERM_TYPE, e.mColumns, e.mRows)
    }

    private fun deliver(bytes: ByteArray) {
        val e = emulator
        if (e == null) {
            // Losing the first prompt on a server that prints it once looks
            // exactly like a hang. Buffering is cheap; the failure is not.
            pending += bytes
        } else {
            e.append(bytes, bytes.size)
        }
    }

    private fun flushPending() {
        val e = emulator ?: return
        pending.forEach { e.append(it, it.size) }
        pending.clear()
    }

    // --- TerminalOutput ---

    override fun write(data: ByteArray, offset: Int, count: Int) {
        val slice = data.copyOfRange(offset, offset + count)
        scope.launch { transport.write(slice) }
    }

    fun writeCodePoint(prependEscape: Boolean, codePoint: Int) {
        val text = buildString {
            if (prependEscape) append('')
            appendCodePoint(codePoint)
        }
        write(text)
    }

    override fun titleChanged(oldTitle: String?, newTitle: String?) {
        title = newTitle
        client.onTitleChanged(this)
    }

    override fun onCopyTextToClipboard(text: String?) = client.onCopyTextToClipboard(this, text)
    override fun onPasteTextFromClipboard() = client.onPasteTextFromClipboard(this)
    override fun onBell() = client.onBell(this)
    override fun onColorsChanged() = client.onColorsChanged(this)

    fun close() {
        transport.disconnect()
    }

    private companion object {
        const val TERM_TYPE = "xterm-256color"
        val TRANSCRIPT_ROWS: Int = 2000
    }
}
```

If `TerminalEmulator`'s field names (`mColumns`, `mRows`, `screen`) or `resize` signature differ at this commit, match the vendored file — it is the authority.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:terminal:testDebugUnitTest :core:terminal:assembleDebug
```

Expected: PASS, 8 tests; `BUILD SUCCESSFUL`.

- [ ] **Step 9: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/terminal
git commit -m "feat(android): Termux 터미널 벤더링 + SSH 백엔드 TerminalSession"
```

---

### Task 5: `:feature:settings` — SSH section and key import

**Files:**
- Modify: `.../feature/settings/SettingsViewModel.kt`, `SettingsScreen.kt`, `SettingsNavigation.kt`
- Create: `.../feature/settings/SshKeyScreen.kt`, `SshKeyViewModel.kt`
- Test: `android/feature/settings/src/test/kotlin/.../SshKeyViewModelTest.kt`

**Interfaces:**
- Consumes: `SecureStore.getSshPrivateKey/setSshPrivateKey`, `SettingsSource.sshUsername` (Task 2).
- Produces: `const val SSH_KEY_ROUTE = "settings/ssh-key"`, `SshKeyViewModel` with `state: StateFlow<SshKeyUiState>`, `onPemChange`, `save()`, `delete()`.

- [ ] **Step 1: Write the failing key-screen tests**

```kotlin
package com.hydra.android.feature.settings

import app.cash.turbine.test
import com.hydra.android.core.data.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class KeyStore(var api: String? = null, var ssh: String? = null) : SecureStore {
    override fun getApiKey() = api
    override fun setApiKey(value: String) { api = value.ifEmpty { null } }
    override fun getSshPrivateKey() = ssh
    override fun setSshPrivateKey(value: String) { ssh = value.ifEmpty { null } }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SshKeyViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `reports whether a key is already stored`() = runTest {
        val vm = SshKeyViewModel(KeyStore(ssh = "PEM"))
        vm.state.test {
            assertTrue(awaitItem().hasStoredKey)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `saving writes the trimmed pem and reports success`() = runTest {
        val store = KeyStore()
        val vm = SshKeyViewModel(store)
        vm.onPemChange("  PEMBODY \n")
        vm.save()
        advanceUntilIdle()
        assertEquals("PEMBODY", store.ssh)
        vm.state.test {
            val s = awaitItem()
            assertTrue(s.hasStoredKey)
            assertEquals("저장됨", s.message)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `saving an empty pem is refused rather than clearing the stored key`() = runTest {
        val store = KeyStore(ssh = "EXISTING")
        val vm = SshKeyViewModel(store)
        vm.onPemChange("   ")
        vm.save()
        advanceUntilIdle()
        assertEquals("EXISTING", store.ssh)
        vm.state.test {
            assertEquals("키 내용이 비어 있습니다", awaitItem().message)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `delete clears the stored key and the editor`() = runTest {
        val store = KeyStore(ssh = "PEM")
        val vm = SshKeyViewModel(store)
        vm.delete()
        advanceUntilIdle()
        assertNull(store.ssh)
        vm.state.test {
            val s = awaitItem()
            assertFalse(s.hasStoredKey)
            assertEquals("", s.pem)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:settings:testDebugUnitTest
```

Expected: FAIL — unresolved reference `SshKeyViewModel`.

- [ ] **Step 3: Write `SshKeyViewModel`**

```kotlin
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
```

- [ ] **Step 4: Write `SshKeyScreen`**

A `Scaffold` titled "SSH 키" containing, in a scrolling column:
- A status line: `"키 저장됨 ✓"` in `HydraGreen` when `hasStoredKey`, else `"저장된 키 없음"` in `onSurfaceVariant`.
- An `OutlinedTextField` bound to a **screen-owned buffer** (the v1 pattern — see `SettingsScreen`), `fontFamily = FontFamily.Monospace`, `minLines = 8`, label `"SSH 개인키 (PEM)"`.
- A `"파일에서 가져오기"` button launching `rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument())` with `arrayOf("*/*")`; on a returned `Uri`, read it via `context.contentResolver.openInputStream(uri)?.bufferedReader()?.readText()` and push it into both the buffer and `viewModel.onPemChange`.
- A `"저장"` button and, when `hasStoredKey`, a `"삭제"` `TextButton` in `colorScheme.error`.
- `state.message` rendered below in `bodySmall`.

The text buffer must be screen-owned, not bound to `state.pem` directly: v1 hit real keystroke loss binding a field straight to ViewModel state, and a PEM is long enough to make it obvious.

- [ ] **Step 5: Add the SSH section to Settings**

In `SettingsViewModel`, mirror the existing `serverUrl` mirror pattern for the username:

```kotlin
    private val sshUsernameInput = MutableStateFlow("")
```

seeded in `init` from `settings.sshUsername.first()` under the same `edited` guard, added to `SettingsUiState` as `val sshUsername: String = ""`, exposed through the existing `combine` (which now needs the 5-argument overload), and written by:

```kotlin
    fun onSshUsernameChange(value: String) {
        edited = true
        sshUsernameInput.value = value
        viewModelScope.launch { settings.setSshUsername(value) }
    }
```

In `SettingsScreen`, after the AI section, add:

```
HorizontalDivider()
Text("SSH", style = MaterialTheme.typography.titleSmall)
OutlinedTextField(username, label = "username", singleLine, KeyboardCapitalization.None)
TextButton(onClick = onOpenSshKey) { Text("SSH 키 관리") }
```

`SettingsScreen` takes a new `onOpenSshKey: () -> Unit` parameter. In `SettingsNavigation.kt`:

```kotlin
const val SETTINGS_ROUTE = "settings"
const val SSH_KEY_ROUTE = "settings/ssh-key"

fun NavGraphBuilder.settingsScreen(
    onOpenSshKey: () -> Unit,
    onBack: () -> Unit,
) {
    composable(SETTINGS_ROUTE) { SettingsScreen(onOpenSshKey = onOpenSshKey) }
    composable(SSH_KEY_ROUTE) { SshKeyScreen(onBack = onBack) }
}
```

- [ ] **Step 6: Run the tests**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:settings:testDebugUnitTest :feature:settings:assembleDebug
```

Expected: PASS — the 10 v1 settings tests plus 4 here = 14; `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/feature/settings
git commit -m "feat(android): 설정 SSH 섹션 + 개인키 가져오기 화면"
```

---

### Task 6: `:feature:devices` — the device list

**Files:**
- Modify: `android/feature/devices/build.gradle.kts`
- Create: `.../feature/devices/DevicesViewModel.kt`, `DevicesScreen.kt`, `DevicesNavigation.kt`
- Test: `android/feature/devices/src/test/kotlin/.../DevicesViewModelTest.kt`

**Interfaces:**
- Consumes: `HydraApi.listDevices` and `apiCall` from `:core:network`, `Device` from `:core:model`.
- Produces: `const val DEVICES_ROUTE = "devices"`, `fun NavGraphBuilder.devicesScreen(onSelectDevice: (String) -> Unit)`, `DevicesViewModel` with `state: StateFlow<DevicesUiState>` and `refresh()`.

- [ ] **Step 1: Write the module build file**

Same block as `:feature:settings` in v1, with `android { namespace = "com.hydra.android.feature.devices" }` and additionally `implementation(project(":core:network"))`.

- [ ] **Step 2: Write the failing ViewModel test**

```kotlin
package com.hydra.android.feature.devices

import app.cash.turbine.test
import com.hydra.android.core.model.Device
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val T0 = Instant.parse("2026-09-03T10:00:00Z")

private fun device(id: String, ssh: Boolean = true, status: String = "online") =
    Device(id = id, hostname = id, status = status, lastSeen = T0, sshEnabled = ssh)

private class FakeRepo(
    private val result: () -> List<Device>,
) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = runCatching { result() }
}

@OptIn(ExperimentalCoroutinesApi::class)
class DevicesViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `loads devices on first subscription`() = runTest {
        val vm = DevicesViewModel(FakeRepo { listOf(device("d1"), device("d2")) })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals(2, s.devices.size)
            assertNull(s.error)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failure surfaces the message and leaves the list empty`() = runTest {
        val vm = DevicesViewModel(FakeRepo { throw ApiException(null, "서버에 연결할 수 없습니다") })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("서버에 연결할 수 없습니다", s.error)
            assertTrue(s.devices.isEmpty())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `devices without ssh are reported as not selectable`() = runTest {
        val vm = DevicesViewModel(FakeRepo { listOf(device("d1", ssh = false)) })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            assertEquals(false, expectMostRecentItem().devices.single().sshEnabled)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `refresh reloads`() = runTest {
        var calls = 0
        val vm = DevicesViewModel(FakeRepo { calls++; emptyList() })
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            vm.refresh()
            advanceUntilIdle()
            assertEquals(2, calls)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:devices:testDebugUnitTest
```

Expected: FAIL — `DevicesRepository`, `DevicesViewModel` undefined.

- [ ] **Step 4: Write the repository and ViewModel**

Add to `:core:data` a `DevicesRepository` (the device list is data, not feature-local):

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.Device
import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import javax.inject.Inject
import javax.inject.Singleton

interface DevicesRepository {
    suspend fun list(): Result<List<Device>>
}

@Singleton
class ApiDevicesRepository @Inject constructor(
    private val api: HydraApi,
) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = apiCall { api.listDevices() }
}
```

Bind it in `DataModule`:

```kotlin
    @Provides
    @Singleton
    fun provideDevicesRepository(api: HydraApi): DevicesRepository = ApiDevicesRepository(api)
```

Move the `DevicesRepository` import in the test to `com.hydra.android.core.data`.

`DevicesViewModel.kt`:

```kotlin
package com.hydra.android.feature.devices

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.model.Device
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest
import javax.inject.Inject

data class DevicesUiState(
    val devices: List<Device> = emptyList(),
    val isLoading: Boolean = true,
    val error: String? = null,
)

@HiltViewModel
class DevicesViewModel @Inject constructor(
    private val repository: DevicesRepository,
) : ViewModel() {

    private val reloads = MutableSharedFlow<Unit>(
        replay = 0, extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    val state: StateFlow<DevicesUiState> = reloads
        .map { }
        .onStart { emit(Unit) }
        .transformLatest {
            val result = repository.list()
            emit(
                DevicesUiState(
                    devices = result.getOrDefault(emptyList()),
                    isLoading = false,
                    error = result.exceptionOrNull()?.message,
                )
            )
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DevicesUiState())

    fun refresh() {
        reloads.tryEmit(Unit)
    }
}
```

- [ ] **Step 5: Write the screen and navigation**

`DevicesScreen` is a `Scaffold` titled "디바이스" wrapping a `PullToRefreshBox` over a `LazyColumn`:
- The error, when present, as the first item in `colorScheme.error`.
- One row per device: `StatusDot(device.isOnline)`, `device.displayName` in `titleSmall`, `device.tailscaleIp` in `labelSmall` / `onSurfaceVariant`, and a trailing `Icons.Filled.Terminal` icon when `sshEnabled`.
- Rows use `Modifier.clickable(enabled = device.sshEnabled) { onSelectDevice(device.id) }`; a disabled row renders its text at `alpha = 0.4f`. This is `DeviceListScreen.swift`'s `.disabled(!device.sshEnabled)`.
- A centered `CircularProgressIndicator` while `isLoading && devices.isEmpty()`.

`DevicesNavigation.kt`:

```kotlin
package com.hydra.android.feature.devices

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val DEVICES_ROUTE = "devices"

fun NavGraphBuilder.devicesScreen(onSelectDevice: (String) -> Unit) {
    composable(DEVICES_ROUTE) { DevicesScreen(onSelectDevice = onSelectDevice) }
}
```

- [ ] **Step 6: Run the tests**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest :feature:devices:testDebugUnitTest \
            :feature:devices:assembleDebug
```

Expected: PASS, 4 device tests; `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data android/feature/devices
git commit -m "feat(android): 디바이스 탭 — 목록 + SSH 가능 여부 게이트"
```

---

### Task 7: `:feature:terminal` — ViewModel and screen

**Files:**
- Modify: `android/feature/terminal/build.gradle.kts`
- Create: `.../feature/terminal/TerminalViewModel.kt`, `TerminalScreen.kt`, `HydraTerminalViewClient.kt`, `TerminalNavigation.kt`
- Test: `android/feature/terminal/src/test/kotlin/.../TerminalViewModelTest.kt`

**Interfaces:**
- Consumes: `SshTransport`, `SshCredentialResolver`, `HostKeyFingerprint`, `SshError` (Tasks 2-3); `TerminalSession` (Task 4); `DevicesRepository` (Task 6).
- Produces: `const val TERMINAL_ROUTE = "terminal/{deviceId}"`, `fun terminalRoute(deviceId: String): String`, `fun NavGraphBuilder.terminalScreen(onClose: () -> Unit)`.

- [ ] **Step 1: Write the module build file**

Same block as `:feature:devices`, with namespace `com.hydra.android.feature.terminal`, plus `implementation(project(":core:terminal"))`.

- [ ] **Step 2: Write the failing ViewModel test**

```kotlin
package com.hydra.android.feature.terminal

import app.cash.turbine.test
import com.hydra.android.core.ssh.HostKeyFingerprint
import com.hydra.android.core.ssh.SshError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalViewModelTest {

    @get:Rule val temp = TemporaryFolder()

    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private val fp = HostKeyFingerprint("ssh-ed25519", "AAAAKEY", "SHA256:abc")

    /**
     * The behaviours under test — the trust prompt and failure reporting — never
     * reach these collaborators, so the stubs only need to exist.
     */
    private fun viewModel(): TerminalViewModel {
        val devices = object : DevicesRepository {
            override suspend fun list(): Result<List<Device>> = Result.success(emptyList())
        }
        val secureStore = object : SecureStore {
            override fun getApiKey(): String? = null
            override fun setApiKey(value: String) = Unit
            override fun getSshPrivateKey(): String = "PEM"
            override fun setSshPrivateKey(value: String) = Unit
        }
        val settings = object : SettingsSource {
            override val serverUrl = MutableStateFlow("")
            override val aiInstruction = MutableStateFlow("")
            override val hideMobileDevices = MutableStateFlow(false)
            override val sshUsername = MutableStateFlow("root")
            override suspend fun setServerUrl(value: String) = Unit
            override suspend fun setAiInstruction(value: String) = Unit
            override suspend fun setHideMobileDevices(value: Boolean) = Unit
            override suspend fun setSshUsername(value: String) = Unit
        }
        return TerminalViewModel(
            devices = devices,
            credentials = SshCredentialResolver(secureStore, settings),
            knownHosts = KnownHostsStore(File(temp.root, "known_hosts")),
        )
    }

    @Test
    fun `a trust request surfaces the fingerprint to the UI`() = runTest {
        val vm = viewModel()
        val answer = CompletableDeferred<Boolean>()
        vm.state.test {
            awaitItem()
            launchTrust(vm, answer)
            advanceUntilIdle()
            assertEquals("SHA256:abc", expectMostRecentItem().pendingHostKey?.sha256)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `accepting the prompt answers true and clears it`() = runTest {
        val vm = viewModel()
        val answer = CompletableDeferred<Boolean>()
        launchTrust(vm, answer)
        advanceUntilIdle()
        vm.acceptHostKey()
        advanceUntilIdle()
        assertTrue(answer.await())
        assertNull(vm.state.value.pendingHostKey)
    }

    @Test
    fun `cancelling the prompt answers false and clears it`() = runTest {
        val vm = viewModel()
        val answer = CompletableDeferred<Boolean>()
        launchTrust(vm, answer)
        advanceUntilIdle()
        vm.rejectHostKey()
        advanceUntilIdle()
        assertEquals(false, answer.await())
        assertNull(vm.state.value.pendingHostKey)
    }

    @Test
    fun `a connection error is shown as the disconnect reason`() = runTest {
        val vm = viewModel()
        vm.reportFailure(SshError.HostKeyMismatch())
        assertEquals(
            "호스트 키가 저장된 값과 다릅니다 — 연결을 차단했습니다",
            vm.state.value.error,
        )
    }

    /** Drives the suspend callback the transport's verifier would call. */
    private fun kotlinx.coroutines.test.TestScope.launchTrust(
        vm: TerminalViewModel,
        answer: CompletableDeferred<Boolean>,
    ) {
        kotlinx.coroutines.CoroutineScope(dispatcher).launch {
            answer.complete(vm.requestHostKeyTrust(fp))
        }
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:terminal:testDebugUnitTest
```

Expected: FAIL — `TerminalViewModel` undefined.

- [ ] **Step 4: Write `TerminalViewModel`**

```kotlin
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
        viewModelScope.launch {
            val device = devices.list().getOrNull()?.firstOrNull { it.id == deviceId }
            if (device == null) {
                reportFailure(IllegalStateException("디바이스를 찾을 수 없습니다"))
                return@launch
            }
            _state.update { it.copy(deviceName = device.displayName) }

            val creds = runCatching { credentials.resolve() }
                .getOrElse { reportFailure(it); return@launch }

            val transport = SshjTransport(
                verifierFactory = { onTrust -> TofuHostKeyVerifier(knownHosts, onTrust) },
                onNeedsTrust = { fp -> requestHostKeyTrust(fp) },
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
```

- [ ] **Step 5: Write the screen**

`TerminalScreen(deviceId: String, onClose: () -> Unit, viewModel: TerminalViewModel = hiltViewModel())`:

- `LaunchedEffect(deviceId) { viewModel.connect(deviceId) }`.
- `Scaffold` with a `TopAppBar` titled `state.deviceName` and a navigation icon calling `onClose`.
- Body: `AndroidView` whose `factory` builds `TerminalView(ctx, null)`, calls `setTerminalViewClient(HydraTerminalViewClient())`, and — in `update` — calls `attachSession(session)` once `viewModel.session` is non-null.
- When `state.pendingHostKey != null`, an `AlertDialog` titled `"호스트 키를 신뢰할까요?"`, text `state.pendingHostKey!!.sha256`, confirm `"신뢰"` → `viewModel.acceptHostKey()`, dismiss `"취소"` → `viewModel.rejectHostKey()`.
- When `state.error != null`, a bottom-aligned `Surface` strip with the message in `colorScheme.error`.

`HydraTerminalViewClient` implements the vendored `TerminalViewClient`. Match the on-disk interface; return `false` from the key/codepoint hooks so `TerminalView` handles them itself, `12` from `onScale`-style font hooks, and route the log methods to `android.util.Log`.

`TerminalNavigation.kt`:

```kotlin
package com.hydra.android.feature.terminal

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument

const val TERMINAL_ROUTE = "terminal/{deviceId}"

fun terminalRoute(deviceId: String) = "terminal/$deviceId"

fun NavGraphBuilder.terminalScreen(onClose: () -> Unit) {
    composable(
        TERMINAL_ROUTE,
        arguments = listOf(navArgument("deviceId") { type = NavType.StringType }),
    ) { entry ->
        TerminalScreen(
            deviceId = entry.arguments?.getString("deviceId").orEmpty(),
            onClose = onClose,
        )
    }
}
```

- [ ] **Step 6: Run the tests and build**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:terminal:testDebugUnitTest :feature:terminal:assembleDebug
```

Expected: PASS, 4 tests; `BUILD SUCCESSFUL`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/feature/terminal
git commit -m "feat(android): 터미널 화면 + TOFU 신뢰 프롬프트"
```

---

### Task 8: `:app` — four tabs, the terminal route, and real-device verification

**Files:**
- Modify: `android/app/build.gradle.kts`, `.../android/HydraApp.kt`
- Test: `android/app/src/test/kotlin/com/hydra/android/NavigationRoutesTest.kt`

**Interfaces:**
- Consumes: `DEVICES_ROUTE` / `devicesScreen`, `TERMINAL_ROUTE` / `terminalRoute` / `terminalScreen`, `SSH_KEY_ROUTE`.
- Produces: the shipped app.

- [ ] **Step 1: Add the feature dependencies**

In `android/app/build.gradle.kts`, add to `dependencies`:

```kotlin
    implementation(project(":feature:devices"))
    implementation(project(":feature:terminal"))
```

- [ ] **Step 2: Update the failing route test**

```kotlin
    @Test
    fun `bottom tabs are ordered dashboard, devices, chat, settings`() {
        assertEquals(
            listOf(DASHBOARD_ROUTE, DEVICES_ROUTE, CHAT_ROUTE, SETTINGS_ROUTE),
            HydraDestination.entries.map { it.route },
        )
    }

    @Test
    fun `tab labels match the iOS wording`() {
        assertEquals(
            listOf("대시보드", "디바이스", "Chat", "설정"),
            HydraDestination.entries.map { it.label },
        )
    }

    @Test
    fun `the terminal is not a tab`() {
        // It is a full-screen route, matching iOS's fullScreenCover.
        assertTrue(HydraDestination.entries.none { it.route.startsWith("terminal") })
    }

    @Test
    fun `terminalRoute substitutes the device id`() {
        assertEquals("terminal/d1", terminalRoute("d1"))
    }
```

Keep the existing "start destination is the dashboard" and "routes are unique" tests.

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :app:testDebugUnitTest
```

Expected: FAIL — the tab list has three entries, and `DEVICES_ROUTE` / `terminalRoute` are unresolved.

- [ ] **Step 4: Add the tab and the route**

In `HydraApp.kt`, add to the enum between DASHBOARD and CHAT:

```kotlin
    DEVICES(DEVICES_ROUTE, "디바이스", Icons.Filled.Dns),
```

Hide the bar on full-screen routes and register the new destinations:

```kotlin
    val hideBottomBar = currentRoute?.startsWith("terminal/") == true ||
        currentRoute == SSH_KEY_ROUTE

    Scaffold(
        bottomBar = { if (!hideBottomBar) { NavigationBar { /* unchanged */ } } }
    ) { padding ->
        NavHost(...) {
            dashboardScreen()
            devicesScreen(onSelectDevice = { id -> navController.navigate(terminalRoute(id)) })
            chatScreen()
            settingsScreen(
                onOpenSshKey = { navController.navigate(SSH_KEY_ROUTE) },
                onBack = { navController.popBackStack() },
            )
            terminalScreen(onClose = { navController.popBackStack() })
        }
    }
```

- [ ] **Step 5: Run the full suite and build the APK**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew testDebugUnitTest assembleDebug
```

Expected: `BUILD SUCCESSFUL`, every module's tests green, `app/build/outputs/apk/debug/app-debug.apk` present.

- [ ] **Step 6: Verify against a real SSH host**

The emulator reaches the host machine at `10.0.2.2`. Enable Remote Login on the Mac (System Settings → General → Sharing → Remote Login) so there is a real SSH server to reach, and authorize a key:

```bash
ssh-keygen -t ed25519 -f /tmp/hydra-android-test -N "" -C "hydra-android-test"
cat /tmp/hydra-android-test.pub >> ~/.ssh/authorized_keys
cat /tmp/hydra-android-test          # paste this into the app
```

Then, with the emulator running and the backend up:

```bash
cd /Users/dave/iWorks/hydra && ./build/hydra-server &
cd android && JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :app:installDebug
```

Confirm by hand, and report what you actually saw:

1. 설정 → SSH: set username to your macOS short name, open "SSH 키 관리", paste the private key, save. Reopen the screen — it still says 키 저장됨.
2. 디바이스 tab: the list loads; a device without SSH is greyed and does not respond to a tap.
3. Tap an SSH-capable device pointing at `10.0.2.2` (add it to the server, or temporarily change the device's address): the trust dialog appears with a `SHA256:` fingerprint.
4. Accept: a shell prompt renders. Type `uname -a` and see output. The bottom tab bar is hidden.
5. Rotate the device or open the keyboard: the terminal reflows and the remote `tput cols` reports the new width.
6. Back out and re-enter the same device: **no** trust prompt this time (the key is now in `known_hosts`).
7. Corrupt trust deliberately: `adb shell run-as com.hydra.android sh -c 'sed -i s/./X/20 files/known_hosts'`, then reconnect — expect the blocked message, and **no** dialog.
8. Clear the stored key in 설정 and connect: expect `SSH 키가 저장되어 있지 않습니다` before any network attempt.

Afterwards, remove the test key from `~/.ssh/authorized_keys` and turn Remote Login back off.

If no emulator or SSH host is available, say so explicitly rather than reporting this step as done.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android
git commit -m "feat(android): 디바이스 탭 배선 + 터미널 전체화면 라우트"
```

---

## Self-Review

**Spec coverage.** Module graph → Tasks 1, 4, 6, 7. Vendoring list, exclusions, `VENDORED.md` → Task 4. Drop-in replacement rationale and the four call sites → Task 4. `SshTransport` contract → Task 2. sshj dependencies, BouncyCastle swap, slf4j binding, packaging excludes → Tasks 1 and 3. Credentials and the `sshUsername` reversal → Task 2. TOFU inside the verifier → Task 3. Known-hosts simplification, keyType matching kept and hashed-host support dropped → Task 1. Emulator lifecycle, startup rendezvous, main-thread confinement → Task 4. Compose interop → Task 7. Navigation and the hidden bottom bar → Task 8. Settings SSH section and key import → Task 5. Error message table → Task 2 (`SshError`) and Task 7 (surfacing). Every testing-strategy row maps to a task's test step; manual verification is Task 8 Step 6.

**Interface changes discovered while planning, recorded where they belong:** `SecureStore` grows SSH-key accessors and `SettingsSource` grows `sshUsername` (Task 2, Step 4), which breaks three v1 test fakes — Task 2 Step 5 names all three files rather than leaving the executor to discover them. `DevicesRepository` lands in `:core:data`, not `:feature:devices`, because the terminal needs it too (Task 6 Step 4, consumed in Task 7).

**Type consistency.** `HostKeyFingerprint(keyType, publicKeyBase64, sha256)` is produced in Task 1 and consumed unchanged in Tasks 3 and 7. `TofuHostKeyVerifier(store, onNeedsTrust)` and its `decide`/`lastDecision` members are defined in Task 3 and constructed in Task 7 with the same argument order. `TerminalSession(transport, scope, onTitleChanged, onBell, onCopyToClipboard, onPasteFromClipboard)` is defined in Task 4 and constructed identically in Task 7. `SshError`'s subclasses are referenced by the same names in Tasks 2, 3 and 7.

**Known soft spot.** Task 4's `TerminalSession` and Task 7's `HydraTerminalViewClient` are written against vendored interfaces read at commit `3b66f87`. Both tasks say explicitly that the file on disk is the authority if a signature differs; the compile step in each task is what catches it.
