# Terminal final-review fixes (C1, I1, I2, I3)

Branch: `feature/in-app-ssh-terminal`

## C1 (CRITICAL) — CitadelSession.remoteHostKey always nil → real nodes always .blocked

File: `Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift`

**Root cause**: `connect()` used `hostKeyValidator: .acceptAnything()`, which never surfaces
the presented host key back to the caller. `remoteHostKey` stayed `nil` forever, so
`HostKeyGate.evaluate(fingerprint: nil, ...)` always returned `.blocked` — every real
SSH connection disconnected immediately after handshake.

**Citadel/NIOSSH API used**:
- `SSHHostKeyValidator.custom(_ validator: NIOSSHClientServerAuthenticationDelegate)` —
  found in `Citadel/Sources/Citadel/ClientSession.swift`. This is the escape hatch Citadel
  exposes alongside `.trustedKeys(_:)` and `.acceptAnything()`; it forwards directly to
  whatever `NIOSSHClientServerAuthenticationDelegate` you supply.
- `NIOSSHClientServerAuthenticationDelegate.validateHostKey(hostKey: NIOSSHPublicKey,
  validationCompletePromise: EventLoopPromise<Void>)` — the NIOSSH protocol
  (`swift-nio-ssh/Sources/NIOSSH/Keys And Signatures/ClientServerAuthenticationDelegate.swift`).
  Implementations must succeed/fail the promise; we always succeed it (accept-anything is
  still the *transport*-layer posture — TOFU enforcement stays app-layer in `HostKeyGate`,
  per the existing design), but first we capture the presented `NIOSSHPublicKey`.
- To render the captured key into a fingerprint we used NIOSSH's own public initializer
  `String(openSSHPublicKey: NIOSSHPublicKey)` (in `NIOSSHPublicKey.swift`), which returns
  `"<algorithm-id> <base64-key>"` — the exact SSH wire encoding (`writeSSHHostKey`) that
  NIOSSH itself already uses. We deliberately did NOT hand-roll the wire serialization
  (writing the type-prefixed SSH string ourselves) because `NIOSSHPublicKey.keyPrefix` and
  the `write(to:)` "without header" helpers are `internal`, not public API — the public
  `String(openSSHPublicKey:)` initializer was the intended supported path and matches what
  a `known_hosts`-style renderer would produce.
- We split that rendered string on the first space to get `keyType` and `publicKeyBase64`,
  then computed `sha256Hex` via `Crypto.SHA256.hash(data:)` over the base64-decoded raw key
  bytes (hex-encoded via `String(format: "%02x", byte)`).

**Retain-cycle avoidance**: rather than making `CitadelSession` itself conform to
`NIOSSHClientServerAuthenticationDelegate` and passing `.custom(self)`, we added a small
private `HostKeyCapturingValidator` class that wraps a `[weak self]` closure. Reason:
`CitadelSession` strongly owns `client: SSHClient?`, and `SSHClient`'s settings strongly
own the `hostKeyValidator`. Passing `self` directly would create
`CitadelSession -> SSHClient -> validator -> CitadelSession`, a retain cycle that only
breaks if `disconnect()` (which nils `client`) is guaranteed to run before the session is
otherwise dropped. The closure-wrapping validator has no such dependency.

**Package.swift**: `Hydra/Packages/TerminalCore/Package.swift` — the `SSHTransportCitadel`
target already `import`ed `NIOCore`, `NIOSSH`, and `Crypto` (used for the existing
Ed25519/RSA key-auth code), but only declared `Citadel` as an explicit package dependency;
those imports were resolving transitively through Citadel's own dependency graph. Since the
C1 patch adds more direct usage of `NIOSSHPublicKey`/`NIOSSHClientServerAuthenticationDelegate`
and `EventLoopPromise`, we added explicit `.package(url:)` entries for `swift-nio`,
`swift-nio-ssh` (pinned to the same `Wellz26` fork/range Citadel itself pins), and
`swift-crypto`, and added `.product(name: "NIOCore", ...)`, `.product(name: "NIOSSH", ...)`,
`.product(name: "Crypto", ...)` to the `SSHTransportCitadel` target's dependencies.

**Verification status**: code-complete but **NOT covered by the automated suite** — the
Fake transport (`FakeSSHSession`) doesn't exercise Citadel/NIOSSH at all, so there is no
way to unit-test the real host-key capture path without a live (or embedded-test) SSH
server. This needs a manual smoke test: connect to a real node, confirm the TOFU sheet
shows a real (non-empty, non-placeholder) SHA256 fingerprint, trust it, confirm the
resulting `~/.ssh/known_hosts`-style entry round-trips (reconnect → `.proceed`, no repeat
prompt), and confirm a deliberately mismatched key (e.g. by pre-seeding
`KnownHostsStore` with a wrong key for that host) hits `.blocked`.

## I2 (Important, security) — KnownHostsStore.trust could corrupt a no-trailing-newline file

File: `Hydra/Packages/TerminalCore/Sources/KnownHosts/KnownHostsStore.swift`

`trust(_:)` previously did `seekToEnd()` + append `entry + "\n"` unconditionally. If the
real `~/.ssh/known_hosts` file existed, was non-empty, and didn't already end in `\n`
(e.g. hand-edited, or written by a tool that omits the final newline), our append would
concatenate directly onto the last existing line, corrupting an entry OpenSSH itself
parses.

Fix: before appending, if the file exists and is non-empty, read the last byte via
`seek(toOffset:)` + `readData(ofLength: 1)`, and if it isn't `0x0A` (`\n`), write a leading
newline first. Empty and already-newline-terminated files are untouched (identical
behavior to before).

## I3 (Important) — KnownHostsStore.check false-blocked multi-key-per-host real files

Files: `Hydra/Packages/TerminalCore/Sources/KnownHosts/KnownHostsStore.swift` (fix applied
here; `KnownHostsParser.swift` was NOT modified — it still leaves any trailing comment
text inside `publicKey`, `check()` now strips it for comparison instead).

Old `check(_:)` matched only the FIRST stored entry with the same `hostPattern`, then did
whole-entry equality (host + keyType + publicKey-with-comment). Two real-world cases broke:
1. A host with both an `ssh-ed25519` and an `ecdsa-sha2-nistp256` entry, where the first
   line in the file happened to be the non-matching type — an ed25519 probe would compare
   against the wrong entry and return `.mismatch` (blocking) instead of `.unknown` (TOFU).
2. Any real OpenSSH-authored line carrying a trailing comment (`host keytype key# comment`
   or `host keytype key some-comment`) would never equal the app's own comment-free entry,
   so `.match` could never be reached even for the objectively same key.

Fix: `check(_:)` now filters stored entries to those whose `(hostPattern, keyType)` BOTH
match the query, and only then compares the base64 key token (first whitespace-delimited
word of `publicKey`, stripping anything after it) for equality. No entries for that
`(host, keyType)` pair → `.unknown` (TOFU), not `.mismatch`. Same pair with an equal key
token → `.match`. Same pair with a different key token → `.mismatch`.

## Vendored-file stamp updates

Per the task, the top-of-file vendoring stamp was updated on both touched vendored files:
`// vendored from iWorks/terminal @ 3b3545e — LOCALLY MODIFIED (see below), re-vendor
requires re-applying these patches`

- `Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift` (C1)
- `Hydra/Packages/TerminalCore/Sources/KnownHosts/KnownHostsStore.swift` (I2 + I3)

`KnownHostsParser.swift` and `SSHSession.swift`/`FakeSSHSession.swift` were left untouched
(no stamp change) — I3's fix lives entirely in `KnownHostsStore.check`, not the parser.

## I1 (Important) — reconnect reused a dead SSHSession → blank terminal after disconnect

File: `Hydra/Hydra/Services/TerminalSession.swift` (not vendored, no stamp).

`TerminalSession` used to hold a single injected `SSHSession` for its whole lifetime. Once
`disconnect()` ran on that session, its `output`/`state` `AsyncStream`s were finished
permanently (NIOSSH/Fake sessions can't "restart" a finished `AsyncStream.Continuation`),
so a subsequent `connect()` on the same `TerminalSession` pumped from dead streams and the
terminal just stayed blank.

Fix: `TerminalSession.init` now takes `sessionFactory: @escaping () -> SSHSession` instead
of a fixed `session: SSHSession`. `connect()` cancels any leftover `pumpTask`/
`statePumpTask` from a prior connection, then calls `sessionFactory()` to mint a fresh
session before doing anything else. `TerminalSessionStore.open(device:)` already had a
per-device `sessionFactory: (Device) -> SSHSession`; it now passes
`{ [sessionFactory] in sessionFactory(device) }` into the `TerminalSession` it creates
(explicit capture needed — the closure parameter and the property share the name
`sessionFactory`, so Swift requires an explicit capture list to disambiguate).

Tests: all three existing `TerminalSession(device:session:knownHostsURL:)` call sites in
`Tests/HydraTests/TerminalSessionTests.swift` were switched to
`TerminalSession(device:sessionFactory: { FakeSSHSession() }, knownHostsURL:)`. Added
`testReconnectAfterDisconnectStreamsOutput`: connect + trust TOFU + assert output, call
`session.close()` (which disconnects the underlying session), reconnect on the *same*
`TerminalSession` instance, and assert fresh `"fake$"` output flows again (host key is
already trusted from the first connect, so the second connect proceeds straight through
`HostKeyGate` without a new TOFU prompt).

### I1 hardening — double-tap reconnect safety

A subsequent hardening was applied: `connect(cols:rows:)` now calls `session.disconnect()`
immediately before minting the fresh `sessionFactory()` session (line 58). This guards
against an edge case where `connect()` is called while a live SSH connection still exists
(e.g. if UI calls reconnect while the state machine is still in `.connected`). The old
session's live SSH client would otherwise be stranded (CitadelSession/FakeSSHSession have
no deinit to auto-close). `disconnect()` is idempotent — calling it on an already-closed
session is a safe no-op — so existing tests (which call `connect()` at most once, or call
`close()` before reconnect) are unaffected. All 64 tests pass; no regressions.

## Verification

- `cd Hydra && swift build` — clean (no new warnings; pre-existing Swift 6 mode warnings
  in unrelated files like `OfflineQueue.swift`/`PYExecutor.swift`/`ConsoleViewModel.swift`
  are unchanged).
- `cd Hydra && swift test` — 64 tests, 0 failures, including the new
  `testReconnectAfterDisconnectStreamsOutput` and all pre-existing
  `TerminalSessionTests`/`VendoredTerminalCoreTests`/`HostKeyDecisionTests` cases.
- Confirmed no test writes to the real `~/.ssh/known_hosts` — every `TerminalSession`/
  `KnownHostsStore` test constructs a per-test temp file under
  `FileManager.default.temporaryDirectory`.
