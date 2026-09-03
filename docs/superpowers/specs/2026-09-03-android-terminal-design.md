# Hydra Android — 디바이스 탭 + SSH 터미널 (v2) — Design

## Context

The Android client shipped in v1 with three tabs (설정 · 대시보드 · Chat) against the Go backend's REST API. Its spec (`docs/superpowers/specs/2026-09-02-android-client-design.md`) deferred the SSH terminal explicitly: "the hardest subsystem (terminal emulator + SSH client + host-key trust) and the largest single risk", along with the 디바이스 tab that launches it, `sshUsername`, and SSH key management.

This spec covers that deferred work. The reference implementation is iOS: `HydraiOS/Screens/DeviceListScreen.swift` (39 lines, list only) and `HydraiOS/Terminal/TerminalScreen.swift` over the shared `Hydra/Services/TerminalSession.swift` (389 lines) and the `TerminalCore` Swift package (`SSHTransport`, `KnownHosts`, `SSHTransportCitadel`).

Two library facts, established by checking rather than assuming, shape everything below:

1. **SSH is solved.** `com.hierynomus:sshj:0.40.0` is on Maven Central under Apache-2.0. iOS's `SSHSession` protocol is seven methods, which maps to a Kotlin interface almost verbatim.
2. **The terminal emulator is not.** Maven Central has no published Android terminal-emulator or terminal-view library (`terminal-emulator`, `terminalview`, `ansi-terminal` all return zero results; `org.connectbot:sshlib` is SSH, not a view). The only realistic source is Termux, whose root `LICENSE.md` carves `terminal-emulator` and `terminal-view` out of its GPLv3 as **Apache-2.0** (they derive from jackpal's Android-Terminal-Emulator). So the emulator is **vendored source**, not a dependency.

## Goals

- 디바이스 tab at parity with iOS: a list that launches a full-screen terminal.
- A working SSH terminal against a real device: connect, authenticate with an imported key, TOFU host-key trust, interactive shell, resize, disconnect.
- SSH key **import** (paste or file) into Keystore-backed storage, and the `sshUsername` setting that v1 deliberately omitted.
- Vendor Termux's terminal with the smallest possible patch surface, and record provenance so upstream updates stay tractable.

## Non-Goals

- **SSH key generation.** iOS's `KeyImportScreen` generates Ed25519 keys and exports the public half; that needs OpenSSH private-key format serialization written by hand. Import-only reaches a working terminal sooner. Later cycle.
- **Password authentication.** Neither iOS nor macOS offers it; adding it on Android alone would split client behaviour.
- **tmux session persistence.** iOS has an opt-in tmux bootstrap (`terminalPersistViaTmux`) with a delicate "inject when the shell goes idle" heuristic. Not needed to make a terminal work.
- **Multi-key offer loop.** iOS walks an ordered key list the way OpenSSH does, because macOS has a `~/.ssh` full of keys. Android stores exactly one imported key.
- **Device detail screen** (ping, metrics history, `ssh/diagnose`, `ssh/reset`). The dashboard already shows per-device metrics; iOS's device tab has no detail screen either.
- **Hashed known_hosts entries.** See "Known hosts" below.
- Release signing, ProGuard/R8 rules. Debug builds only, as in v1.

## Architecture overview

### New modules

```
:app
 ├── :feature:devices ──┐
 └── :feature:terminal ─┤
                        ▼
                  :core:terminal  ──► :core:ssh ──► :core:data
             (vendored Termux +      (SshTransport,   (SecureStore,
              our TerminalSession)    sshj, TOFU)      SettingsSource)
```

`:core:terminal` holds both vendored and first-party code, separated by directory and language:

| Path | Ownership |
|---|---|
| `src/main/java/com/termux/**` | Vendored, unmodified |
| `src/main/kotlin/com/termux/terminal/TerminalSession.kt` | Ours — the replacement |
| `src/main/kotlin/com/hydra/android/core/terminal/HydraSessionClient.kt` | Ours — `TerminalSessionClient` implementation |
| `VENDORED.md` | Upstream commit, file list, what was excluded and why |

`TerminalSessionClient` is a vendored interface of 16 methods, every one of which takes our `TerminalSession`. Most are logging hooks; `setTerminalShellPid(session, pid)` is pty-specific and is a no-op for us — a wart inherited from the vendored contract, recorded here so it does not read as an oversight later.

### What gets vendored

From `termux/termux-app`, `terminal-emulator/src/main/java/com/termux/terminal/` — 12 of 14 files:

`ByteQueue`, `KeyHandler`, `Logger`, `TerminalBuffer`, `TerminalColorScheme`, `TerminalColors`, `TerminalEmulator`, `TerminalOutput`, `TerminalRow`, `TerminalSessionClient`, `TextStyle`, `WcWidth`.

**Excluded:** `JNI.java` and `TerminalSession.java`. Termux's `TerminalSession` is `final` and hard-wired to a local pty through `JNI.createSubprocess`, backed by native `libtermux.so`. It cannot be subclassed or reused for SSH. Excluding it also drops the entire `terminal-emulator/src/main/jni/` C tree, so the app needs no NDK.

From `terminal-view/src/main/java/com/termux/view/` — all of it: `TerminalView`, `TerminalRenderer`, `GestureAndScaleRecognizer`, `TerminalViewClient`, plus the `support/` and `textselection/` subpackages.

### Why the replacement class is a drop-in

`TerminalView` (1,500 lines) references the concrete `com.termux.terminal.TerminalSession`, but only calls four things on it:

```
mTermSession.write(...)          ×3
mTermSession.getEmulator()       ×2
mTermSession.writeCodePoint(...) ×1
mTermSession.updateSize(...)     ×1
```

`TerminalViewClient` additionally takes a `TerminalSession` in `onKeyDown` and `onCodePoint`, but only passes it through.

So a Kotlin class in package `com.termux.terminal`, named `TerminalSession`, extending `TerminalOutput` and exposing those four members, satisfies the whole view layer. **`TerminalView` is vendored byte-for-byte with no edits.** That keeps our patch surface at exactly one file, so a future re-vendor diffs cleanly.

Forking `TerminalView` to accept an interface instead (the obvious "cleaner" alternative) was rejected: it buys only the freedom to rename a class, and in exchange puts our edits inside a 1,500-line file that upstream keeps changing.

## SSH layer (`:core:ssh`)

### Transport interface

Mirrors iOS `SSHSession` (`Packages/TerminalCore/Sources/SSHTransport/SSHSession.swift`):

```kotlin
interface SshTransport {
    val output: Flow<ByteArray>
    val state: StateFlow<SshState>
    suspend fun connect(host: String, port: Int, user: String, auth: SshAuth)
    suspend fun openShell(termType: String, cols: Int, rows: Int)
    suspend fun write(data: ByteArray)
    suspend fun resize(cols: Int, rows: Int)
    fun disconnect()
}

sealed interface SshState {
    data object Idle : SshState
    data object Connecting : SshState
    data object Connected : SshState
    data class Disconnected(val reason: String?) : SshState
}

sealed class SshError(message: String) : Exception(message) {
    class Unreachable(m: String) : SshError(m)
    class HandshakeFailed(m: String) : SshError(m)
    class AuthFailed(m: String) : SshError(m)
    class ChannelFailed(m: String) : SshError(m)
    data object Disconnected : SshError("연결이 종료되었습니다")
}
```

`SshjTransport` is the only implementation. All sshj calls run on a dedicated single-thread IO dispatcher — sshj is blocking, and its `HostKeyVerifier` callback needs a thread it may block (see below).

### Dependencies and their Android caveats

`com.hierynomus:sshj:0.40.0` pulls, at runtime scope: `org.slf4j:slf4j-api:2.0.17`, `org.bouncycastle:bcprov-jdk18on:1.80`, `org.bouncycastle:bcpkix-jdk18on:1.80`, `com.hierynomus:asn-one:0.6.0`.

Two consequences that must be handled, not discovered later:

- **BouncyCastle collides with Android's platform provider.** Android ships a stripped-down provider already registered as `"BC"`. sshj needs the full one. At transport initialization: `Security.removeProvider("BC")` then `Security.addProvider(BouncyCastleProvider())`, done once and idempotently.
- **slf4j 2.x needs a binding** or sshj's logging goes nowhere with a startup warning. Use `uk.uuid.slf4j:slf4j-android:2.0.17-0`, which targets the exact slf4j version sshj depends on and routes to Android `Log`. During bring-up those logs are the primary window into handshake failures.

BouncyCastle jars carry `META-INF` signature files that break APK packaging; the `:app` packaging block excludes `META-INF/*.SF`, `META-INF/*.DSA`, `META-INF/*.RSA`, and `META-INF/versions/**`.

### Credentials

Identical in shape to iOS (`TerminalSession.defaultCredentials`): a single private key PEM from `SecureStore`, the `sshUsername` setting, port 22. No key stored is a first-class error (`SshError.AuthFailed("SSH 키가 저장되어 있지 않습니다")`), surfaced before dialing rather than as a handshake failure.

`sshUsername` returns to `SettingsSource` alongside the existing keys. v1's spec removed it on the grounds that "a settings row that controls nothing invites bug reports" — that reasoning expires exactly here, and the reversal is clean.

### Host-key trust (TOFU)

iOS evaluates trust in the app layer *between* `connect()` and `openShell()`, because libssh2 does not enforce host keys itself. sshj does better: `HostKeyVerifier.verify(hostname, port, key)` is called during the handshake, so an untrusted key never reaches an authenticated session.

The verifier is synchronous and returns a boolean, while the trust decision needs the user. The verifier therefore blocks on a `CompletableDeferred<Boolean>` that the ViewModel completes from the prompt. This is safe because the verifier runs on the transport's own IO thread, never the main thread.

Decisions mirror iOS `HostKeyGate`:

| known_hosts lookup | Behaviour |
|---|---|
| `match` | proceed silently |
| `unknown` | prompt with the SHA256 fingerprint; user accepts → store and proceed, cancels → abort |
| `mismatch` | **abort without prompting**, and say why |

A mismatch is not offered as a "trust anyway" button. A changed host key is the exact signature of a machine-in-the-middle, and a dialog trains the user to click through it.

### Known hosts

Storage is an app-private file, one entry per line: `host keyType base64key`. That is known_hosts format minus hashing.

iOS's `KnownHostsStore` carries two local patches. Only one crosses over, and the difference is the point:

- **Key-type-aware matching (iOS patch I3) — kept.** A host legitimately serves several key types (ed25519 *and* rsa). Matching on host alone reports `mismatch` for a host that is merely offering a different type. This is a protocol fact and applies everywhere.
- **Hashed-host support (iOS patch I4) — dropped.** macOS OpenSSH defaults to `HashKnownHosts yes`, so iOS must decode `|1|salt|hash` lines to recognise hosts the user's `ssh` CLI already trusts. Android has no system known_hosts to interoperate with; the code path would be dead weight.

## Terminal session and view

### Our `TerminalSession.kt`

Extends `TerminalOutput`, owns a `TerminalEmulator`, and bridges it to `SshTransport`:

- `write(data, offset, count)` / `writeCodePoint(...)` → `transport.write(...)`
- SSH `output` flow → `emulator.append(...)`
- `updateSize(cols, rows, cellW, cellH)` → creates the emulator on first call, `transport.resize(...)` thereafter
- `getEmulator()` → the emulator, or `null` before first sizing

The emulator is built with the vendored 7-argument constructor, `TerminalEmulator(session, columns, rows, cellWidthPixels, cellHeightPixels, transcriptRows, client)`, passing our session as the `TerminalOutput` and `HydraSessionClient` as the client.

Returning `null` from `getEmulator()` before the first sizing is not a gap — it is Termux's own contract, and `TerminalView` guards on `mEmulator == null` in 15 places.
- `titleChanged` → exposed as a flow the screen renders in the app bar
- `onCopyTextToClipboard` / `onPasteTextFromClipboard` → Android `ClipboardManager`
- `onBell` → short haptic tick; `onColorsChanged` → no-op (no theming UI in this cycle)

**Threading.** `TerminalEmulator` is not thread-safe: Termux reads the pty on a background thread and hands bytes to `mMainThreadHandler` so that `mEmulator.append()` only ever runs on the main thread, which is also where `TerminalView` reads it. We keep the same confinement — the SSH `output` flow is collected on `Dispatchers.Main`.

### Startup ordering

The emulator cannot exist before cols/rows are known, and cols/rows are known only after the view lays out. Two async events must meet:

```
screen enters      → connect()      ┐
                                    ├→ both done → openShell(cols, rows)
view lays out      → updateSize()   ┘   → SSH output → emulator.append()
```

Only after both does the shell open, with the real dimensions.

This is deliberately *not* how iOS does it. iOS opens the shell at a hardcoded 80×24 before layout, then re-applies the true size afterwards — and a resize arriving before `openShell` completes is silently dropped by `LibSSH2Session.resize`'s `guard let shell`, leaving tmux at 80×24 rendering roughly a sixth of a large pane. `lastRequestedSize` / `applyPendingSize` are the scar tissue from that. Opening the shell only once the size is known means the race has no window to occur in.

Output arriving before the emulator exists is buffered and replayed on creation. In the ordering above that window should be empty, but the buffer is cheap and the alternative failure — a lost first prompt on a server without tmux, which iOS also hit — is silent and looks like a hang.

### Compose interop

`TerminalScreen` hosts the view through `AndroidView`:

```
AndroidView(
    factory = { ctx -> TerminalView(ctx, null).apply {
        setTerminalViewClient(client); attachSession(session)
    } },
)
```

`HydraTerminalViewClient` implements `TerminalViewClient` (font size, key handling passthrough, log hooks). The bell, clipboard, and title callbacks arrive through `TerminalOutput` on our session instead.

## Navigation and screens

The bottom bar becomes four tabs: 대시보드 / 디바이스 / Chat / 설정. The terminal is **not** a tab — it is a route `terminal/{deviceId}` outside the bar, and the bar is hidden while it is the current destination. This matches iOS, where the terminal is a `fullScreenCover` rather than a tab.

**디바이스 목록** renders name, Tailscale IP, an online dot, and a terminal icon when `sshEnabled`. Rows for devices without SSH are disabled. Pull-to-refresh reloads. This is `DeviceListScreen.swift` feature-for-feature.

**터미널 화면** shows the device name in the app bar, the terminal filling the rest, a host-key trust dialog when the transport asks for one, and a bottom status strip carrying the disconnect reason when the state is `Disconnected(reason)`.

**설정** gains an SSH section: an `sshUsername` field and an "SSH 키" sub-route with a monospace PEM editor, a "파일에서 가져오기" button using `ActivityResultContracts.OpenDocument`, save, and delete. The key is stored through the existing Keystore-backed `SecureStore`, which already handles arbitrary strings.

## Error handling

`SshError` maps to Korean messages the same way `ApiException` does in v1:

| Cause | Message |
|---|---|
| No key stored | `SSH 키가 저장되어 있지 않습니다` |
| TCP failure / timeout | `서버에 연결할 수 없습니다` |
| Handshake failure | `SSH 핸드셰이크에 실패했습니다` |
| Auth rejected | `인증에 실패했습니다 (키를 서버에 등록했는지 확인하세요)` |
| Host key mismatch | `호스트 키가 저장된 값과 다릅니다 — 연결을 차단했습니다` |
| Shell/channel failure | `셸을 열지 못했습니다` |

The terminal screen never crashes on a failed connect; it shows the reason in the status strip with the terminal area empty.

## Testing strategy

Tests come before the implementation they cover. Vendored Termux code is not tested — it is upstream's, and the boundary we own is `TerminalSession`.

| Module | Coverage |
|---|---|
| `:core:ssh` | `KnownHostsStore`: match / unknown / mismatch; a second key type for a known host reads `unknown`, never `mismatch`. `HostKeyGate`: three decisions plus `blocked` on a missing fingerprint. Credential resolution: missing key produces `AuthFailed` before dialing; default username. |
| `:core:terminal` | With a fake `SshTransport`: output before sizing is buffered then replayed; `openShell` fires only after both auth and sizing, and with the real dimensions; `write`/`writeCodePoint` reach the transport; `updateSize` after creation resizes rather than recreating; `close()` disconnects. |
| `:feature:terminal` | ViewModel: connect state transitions, TOFU prompt accept → proceed, cancel → abort, mismatch → blocked with no prompt, disconnect reason surfaces. |
| `:feature:devices` | List loads; error surfaces; devices with `sshEnabled == false` are not selectable. |

Instrumented Compose tests remain out of scope, as in v1. Verification against a real device is manual, on the emulator, against a reachable SSH host.

## Build integration

`:core:ssh` and `:core:terminal` join the existing `settings.gradle.kts` module list. `make android-build` / `make android-test` cover them with no change. The vendored Java compiles under the existing `hydra.android.library` convention plugin (compileSdk 36, minSdk 26, Java 17 bytecode); it needs no Kotlin.

## Open questions

None blocking. Everything deferred is listed under Non-Goals with its reason.
